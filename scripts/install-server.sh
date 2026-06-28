#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ORIGINAL_ARGS=("$@")
INSTALL_DIR="/opt/conductor"
ENV_FILE="$INSTALL_DIR/conductor.env"
SERVICE_FILE="/etc/systemd/system/conductor.service"
SERVICE_NAME="conductor.service"
PREFERRED_PORT=8080
PORT_EXPLICIT=0
SOURCE_BIN=""
TEMP_ENV=""
TEMP_SERVICE=""

usage() {
  cat <<'EOF'
Usage: install-server.sh [options]

Installs Conductor Server to /opt/conductor and enables its systemd service.

Options:
  --binary <path>  Path to conductor-server. By default, use bin/conductor-server
                   from an extracted release or target/release/conductor-server.
  --port <port>    Preferred listening port. Defaults to 8080. If occupied, the
                   next available port is selected automatically.
  -h, --help       Show this help.
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "Missing value for $option" >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      require_value "$1" "${2:-}"
      SOURCE_BIN="$2"
      shift 2
      ;;
    --port)
      require_value "$1" "${2:-}"
      PREFERRED_PORT="$2"
      PORT_EXPLICIT=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$PREFERRED_PORT" =~ ^[0-9]+$ ]] || (( PREFERRED_PORT < 1 || PREFERRED_PORT > 65535 )); then
  echo "Invalid port: $PREFERRED_PORT" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This installer supports Linux with systemd only." >&2
  exit 1
fi

if (( EUID != 0 )); then
  if command -v sudo >/dev/null 2>&1; then
    echo "Re-running installer with sudo..."
    exec sudo -- "$0" "${ORIGINAL_ARGS[@]}"
  fi
  echo "Run this installer as root." >&2
  exit 1
fi

for command_name in awk chmod chown getent groupadd hostname id install mktemp od rm sed sleep systemctl tr useradd; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
done

if [[ ! -d /run/systemd/system ]]; then
  echo "systemd is not running on this host." >&2
  exit 1
fi

resolve_file() {
  local path="$1"
  local directory
  directory="$(cd "$(dirname "$path")" && pwd)"
  printf '%s/%s\n' "$directory" "$(basename "$path")"
}

if [[ -n "$SOURCE_BIN" ]]; then
  if [[ ! -f "$SOURCE_BIN" ]]; then
    echo "Server binary not found: $SOURCE_BIN" >&2
    exit 1
  fi
  SOURCE_BIN="$(resolve_file "$SOURCE_BIN")"
else
  for candidate in \
    "$PACKAGE_DIR/bin/conductor-server" \
    "$PACKAGE_DIR/target/release/conductor-server"; do
    if [[ -f "$candidate" ]]; then
      SOURCE_BIN="$candidate"
      break
    fi
  done
fi

if [[ -z "$SOURCE_BIN" || ! -x "$SOURCE_BIN" ]]; then
  echo "Unable to find an executable conductor-server binary." >&2
  echo "Extract the Linux release package or use --binary <path>." >&2
  exit 1
fi

cleanup() {
  [[ -z "$TEMP_ENV" ]] || rm -f "$TEMP_ENV"
  [[ -z "$TEMP_SERVICE" ]] || rm -f "$TEMP_SERVICE"
}
trap cleanup EXIT

read_env_value() {
  local path="$1"
  local key="$2"
  [[ -f "$path" ]] || return 0
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$path"
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    printf '\n'
  fi
}

secret_needs_generation() {
  local value="$1"
  [[ -z "$value" || "$value" == dev-* || "$value" == replace-with-* ]]
}

if [[ -r "$ENV_FILE" ]]; then
  EXISTING_ENV_FILE="$ENV_FILE"
elif [[ -r /etc/conductor.env ]]; then
  EXISTING_ENV_FILE="/etc/conductor.env"
else
  EXISTING_ENV_FILE=""
fi

BIND_ADDRESS="0.0.0.0"
JWT_SECRET=""
AGENT_TOKEN=""
if [[ -n "$EXISTING_ENV_FILE" ]]; then
  existing_bind="$(read_env_value "$EXISTING_ENV_FILE" CONDUCTOR_BIND)"
  existing_port="${existing_bind##*:}"
  existing_address="${existing_bind%:*}"
  if (( PORT_EXPLICIT == 0 )) && [[ "$existing_port" =~ ^[0-9]+$ ]] \
      && (( existing_port >= 1 && existing_port <= 65535 )); then
    PREFERRED_PORT="$existing_port"
  fi
  if [[ -n "$existing_address" && "$existing_address" != "$existing_bind" ]]; then
    BIND_ADDRESS="$existing_address"
  fi
  JWT_SECRET="$(read_env_value "$EXISTING_ENV_FILE" CONDUCTOR_JWT_SECRET)"
  AGENT_TOKEN="$(read_env_value "$EXISTING_ENV_FILE" CONDUCTOR_AGENT_TOKEN)"
fi

if secret_needs_generation "$JWT_SECRET"; then
  JWT_SECRET="$(generate_secret)"
fi
if secret_needs_generation "$AGENT_TOKEN"; then
  AGENT_TOKEN="$(generate_secret)"
fi

if [[ ! -r /proc/net/tcp && ! -r /proc/net/tcp6 ]] && ! command -v ss >/dev/null 2>&1; then
  echo "Cannot inspect listening TCP ports: /proc/net/tcp and ss are unavailable." >&2
  exit 1
fi

port_in_use() {
  local port="$1"
  local port_hex
  local table
  local checked_proc=0

  printf -v port_hex '%04X' "$port"
  for table in /proc/net/tcp /proc/net/tcp6; do
    [[ -r "$table" ]] || continue
    checked_proc=1
    if awk -v port="$port_hex" '
      NR > 1 {
        split($2, address, ":")
        if (toupper(address[2]) == port && $4 == "0A") found = 1
      }
      END { exit found ? 0 : 1 }
    ' "$table"; then
      return 0
    fi
  done
  if (( checked_proc == 1 )); then
    return 1
  fi

  ss -H -ltn | awk -v suffix=":$port" '
    length($4) >= length(suffix) && substr($4, length($4) - length(suffix) + 1) == suffix {
      found = 1
    }
    END { exit found ? 0 : 1 }
  '
}

find_available_port() {
  local port="$1"
  while (( port <= 65535 )); do
    if ! port_in_use "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
    ((port += 1))
  done
  echo "No available TCP port found at or above $1." >&2
  return 1
}

echo "Installing Conductor Server"
echo "Source binary: $SOURCE_BIN"
echo "Install directory: $INSTALL_DIR"

systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
PORT="$(find_available_port "$PREFERRED_PORT")"
if [[ "$PORT" != "$PREFERRED_PORT" ]]; then
  echo "Port $PREFERRED_PORT is occupied; selected port $PORT."
else
  echo "Selected port: $PORT"
fi

if ! getent group conductor >/dev/null 2>&1; then
  groupadd --system conductor
fi
if ! id -u conductor >/dev/null 2>&1; then
  NOLOGIN_SHELL="$(command -v nologin || true)"
  [[ -n "$NOLOGIN_SHELL" ]] || NOLOGIN_SHELL="/usr/sbin/nologin"
  useradd --system --gid conductor --home-dir "$INSTALL_DIR" --shell "$NOLOGIN_SHELL" conductor
fi

install -d -m 0755 -o root -g root "$INSTALL_DIR" "$INSTALL_DIR/bin"
install -d -m 0750 -o conductor -g conductor "$INSTALL_DIR/data"
TARGET_BIN="$INSTALL_DIR/bin/conductor-server"
if [[ "$SOURCE_BIN" != "$TARGET_BIN" ]]; then
  install -m 0755 -o root -g root "$SOURCE_BIN" "$TARGET_BIN"
else
  chown root:root "$TARGET_BIN"
  chmod 0755 "$TARGET_BIN"
fi

FRESH_DATABASE=0
if [[ ! -s "$INSTALL_DIR/data/conductor.sqlite3" ]]; then
  FRESH_DATABASE=1
fi

umask 077
TEMP_ENV="$(mktemp)"
cat >"$TEMP_ENV" <<EOF
CONDUCTOR_BIND=$BIND_ADDRESS:$PORT
CONDUCTOR_DB=$INSTALL_DIR/data/conductor.sqlite3
CONDUCTOR_JWT_SECRET=$JWT_SECRET
CONDUCTOR_ADMIN_USERNAME=admin
CONDUCTOR_ADMIN_PASSWORD=888888
CONDUCTOR_AGENT_TOKEN=$AGENT_TOKEN
EOF
install -m 0640 -o root -g conductor "$TEMP_ENV" "$ENV_FILE"

TEMP_SERVICE="$(mktemp)"
cat >"$TEMP_SERVICE" <<EOF
[Unit]
Description=Conductor server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=conductor
Group=conductor
EnvironmentFile=$ENV_FILE
WorkingDirectory=$INSTALL_DIR
ExecStart=$TARGET_BIN
Restart=always
RestartSec=3
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$INSTALL_DIR/data

[Install]
WantedBy=multi-user.target
EOF
install -m 0644 -o root -g root "$TEMP_SERVICE" "$SERVICE_FILE"

systemctl daemon-reload
if ! systemctl enable --now "$SERVICE_NAME"; then
  journalctl -u "$SERVICE_NAME" -n 50 --no-pager >&2 || true
  echo "Failed to enable and start $SERVICE_NAME." >&2
  exit 1
fi

if command -v curl >/dev/null 2>&1; then
  HEALTHY=0
  for ((attempt = 1; attempt <= 30; attempt += 1)); do
    if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
      HEALTHY=1
      break
    fi
    sleep 0.5
  done
  if (( HEALTHY == 0 )); then
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager >&2 || true
    echo "Service started but its health endpoint did not respond." >&2
    exit 1
  fi
else
  sleep 1
fi

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  journalctl -u "$SERVICE_NAME" -n 50 --no-pager >&2 || true
  echo "$SERVICE_NAME is not active." >&2
  exit 1
fi

DISPLAY_HOST="127.0.0.1"
if [[ "$BIND_ADDRESS" != "127.0.0.1" && "$BIND_ADDRESS" != "localhost" ]]; then
  HOST_ADDRESSES="$(hostname -I 2>/dev/null || true)"
  DISPLAY_HOST="$(awk '{ print $1 }' <<<"$HOST_ADDRESSES")"
  [[ -n "$DISPLAY_HOST" ]] || DISPLAY_HOST="<server-ip>"
fi

echo
echo "Conductor Server installed successfully"
echo "---------------------------------------"
echo "Service:        $SERVICE_NAME (enabled, active)"
echo "Install dir:    $INSTALL_DIR"
echo "Configuration:  $ENV_FILE"
echo "Database:       $INSTALL_DIR/data/conductor.sqlite3"
echo "Listen address: $BIND_ADDRESS:$PORT"
echo "Web URL:        http://$DISPLAY_HOST:$PORT"
echo "Agent URL:      ws://$DISPLAY_HOST:$PORT/ws/agent"
echo "Admin username: admin"
if (( FRESH_DATABASE == 1 )); then
  echo "Admin password: 888888"
else
  echo "Admin password: unchanged in existing database (new database default: 888888)"
fi
echo "Agent token:    $AGENT_TOKEN"
echo "JWT secret:     $JWT_SECRET"
echo "Logs:           journalctl -u $SERVICE_NAME -f"
echo
echo "Allow TCP port $PORT in the host firewall when remote access is required."
