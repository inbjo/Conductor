#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <archive-path> [server-bin]" >&2
  exit 2
fi

archive="$1"
server_bin="${2:-target/debug/conductor-server}"
port="${CONDUCTOR_SMOKE_PORT:-18083}"
base_url="http://127.0.0.1:$port"
admin_password="${CONDUCTOR_SMOKE_ADMIN_PASSWORD:-admin123}"
jwt_secret="${CONDUCTOR_SMOKE_JWT_SECRET:-macos-client-e2e-secret}"
agent_token="${CONDUCTOR_SMOKE_AGENT_TOKEN:-macos-client-e2e-token}"
agent_name="${CONDUCTOR_SMOKE_AGENT_NAME:-macos-client-e2e-agent-$$}"

if [[ ! -f "$archive" ]]; then
  echo "Archive not found: $archive" >&2
  exit 1
fi
if [[ ! -x "$server_bin" ]]; then
  echo "Server executable not found: $server_bin" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
agent_root="$tmp_dir/agent-root"
db_path="$tmp_dir/conductor.sqlite3"
server_log="$tmp_dir/server.log"
client_log="$tmp_dir/client.log"
server_pid=""
client_pid=""
agent_bin=""

cleanup() {
  local status=$?
  if [[ -n "$client_pid" ]] && kill -0 "$client_pid" 2>/dev/null; then
    kill "$client_pid" 2>/dev/null || true
  fi
  if [[ -n "$agent_bin" ]]; then
    pkill -f "$agent_bin" 2>/dev/null || true
  fi
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
  fi
  wait "$client_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  if [[ "$status" -ne 0 ]]; then
    echo "macOS client e2e smoke failed. Server log: $server_log" >&2
    tail -n 80 "$server_log" >&2 2>/dev/null || true
    echo "macOS client e2e smoke failed. Client log: $client_log" >&2
    tail -n 80 "$client_log" >&2 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"
  exit "$status"
}
trap cleanup EXIT

mkdir -p "$agent_root"
tar -xzf "$archive" -C "$tmp_dir"

client_bin="$tmp_dir/conductor_client.app/Contents/MacOS/conductor_client"
agent_bin="$tmp_dir/conductor_client.app/Contents/MacOS/conductor-agent"
if [[ ! -x "$client_bin" ]]; then
  echo "Missing or non-executable client binary: $client_bin" >&2
  exit 1
fi
if [[ ! -x "$agent_bin" ]]; then
  echo "Missing or non-executable bundled agent binary: $agent_bin" >&2
  exit 1
fi

if curl -fsS "$base_url/health" >/dev/null 2>&1; then
  echo "Port $port already has a responding service at $base_url." >&2
  exit 1
fi

echo "[1/4] Starting smoke server"
CONDUCTOR_DB="$db_path" \
CONDUCTOR_BIND="127.0.0.1:$port" \
CONDUCTOR_ADMIN_PASSWORD="$admin_password" \
CONDUCTOR_JWT_SECRET="$jwt_secret" \
CONDUCTOR_AGENT_TOKEN="$agent_token" \
"$server_bin" >"$server_log" 2>&1 &
server_pid="$!"

for _ in {1..80}; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "Smoke server exited early." >&2
    exit 1
  fi
  if curl -fsS "$base_url/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
curl -fsS "$base_url/health" | grep -q '"ok":true'

echo "[2/4] Starting client autostart smoke"
CONDUCTOR_CLIENT_AUTOSTART=1 \
CONDUCTOR_CLIENT_AGENT_BIN="$agent_bin" \
CONDUCTOR_SERVER_URL="ws://127.0.0.1:$port/ws/agent" \
CONDUCTOR_AGENT_TOKEN="$agent_token" \
CONDUCTOR_AGENT_NAME="$agent_name" \
CONDUCTOR_AGENT_ROOT="$agent_root" \
CONDUCTOR_INTERACTIVE_APPROVAL=0 \
"$client_bin" >"$client_log" 2>&1 &
client_pid="$!"

echo "[3/4] Logging in"
login_body="$(curl -fsS -X POST "$base_url/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$admin_password\"}")"
token="$(printf '%s' "$login_body" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
if [[ -z "$token" ]]; then
  echo "Login did not return a token: $login_body" >&2
  exit 1
fi

echo "[4/4] Waiting for client-started agent registration"
devices=""
for _ in {1..80}; do
  if ! kill -0 "$client_pid" 2>/dev/null; then
    echo "Client exited before agent registration." >&2
    exit 1
  fi
  devices="$(curl -fsS "$base_url/api/devices" -H "Authorization: Bearer $token")"
  if printf '%s' "$devices" | grep -q "\"hostname\":\"$agent_name\""; then
    break
  fi
  sleep 0.25
done

if ! printf '%s' "$devices" | grep -q "\"hostname\":\"$agent_name\""; then
  echo "Client-started agent did not appear in device list: $devices" >&2
  exit 1
fi
printf '%s' "$devices" | grep -q "\"hostname\":\"$agent_name\".*\"online\":1"

echo "macOS client e2e smoke passed. Agent name: $agent_name"
