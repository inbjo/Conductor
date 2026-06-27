#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="${1:-"$ROOT_DIR/release/conductor-$(rustc -vV | sed -n 's/^host: //p')"}"
PORT="${CONDUCTOR_SMOKE_PORT:-18080}"
BASE_URL="http://127.0.0.1:$PORT"
SERVER_BIN="$RELEASE_DIR/bin/conductor-server"
AGENT_BIN="$RELEASE_DIR/bin/conductor-agent"
DB_PATH="${CONDUCTOR_SMOKE_DB:-/tmp/conductor-smoke-$PORT.sqlite3}"
AGENT_ROOT="${CONDUCTOR_SMOKE_AGENT_ROOT:-/tmp/conductor-smoke-agent-root-$PORT}"
ADMIN_PASSWORD="${CONDUCTOR_SMOKE_ADMIN_PASSWORD:-admin123}"
JWT_SECRET="${CONDUCTOR_SMOKE_JWT_SECRET:-demo-smoke-secret}"
AGENT_TOKEN="${CONDUCTOR_SMOKE_AGENT_TOKEN:-demo-smoke-token}"
AGENT_NAME="${CONDUCTOR_SMOKE_AGENT_NAME:-demo-smoke-agent}"
SERVER_LOG="${CONDUCTOR_SMOKE_SERVER_LOG:-/tmp/conductor-smoke-server-$PORT.log}"
AGENT_LOG="${CONDUCTOR_SMOKE_AGENT_LOG:-/tmp/conductor-smoke-agent-$PORT.log}"
UPLOAD_FILE="/tmp/conductor-smoke-upload-$PORT.txt"
DOWNLOAD_FILE="/tmp/conductor-smoke-download-$PORT.txt"

server_pid=""
agent_pid=""

cleanup() {
  local status=$?
  if [[ -n "$agent_pid" ]] && kill -0 "$agent_pid" 2>/dev/null; then
    kill "$agent_pid" 2>/dev/null || true
  fi
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
  fi
  wait "$agent_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  if [[ "$status" -ne 0 ]]; then
    echo "Smoke test failed. Server log: $SERVER_LOG" >&2
    tail -n 40 "$SERVER_LOG" >&2 2>/dev/null || true
    echo "Smoke test failed. Agent log: $AGENT_LOG" >&2
    tail -n 40 "$AGENT_LOG" >&2 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT

require_file() {
  if [[ ! -x "$1" ]]; then
    echo "Missing executable: $1" >&2
    exit 1
  fi
}

require_file "$SERVER_BIN"
require_file "$AGENT_BIN"
if [[ ! -f "$RELEASE_DIR/SHA256SUMS" ]]; then
  echo "Missing checksum file: $RELEASE_DIR/SHA256SUMS" >&2
  exit 1
fi

rm -f "$DB_PATH" "$DB_PATH-shm" "$DB_PATH-wal" "$UPLOAD_FILE" "$DOWNLOAD_FILE"
rm -rf "$AGENT_ROOT"
mkdir -p "$AGENT_ROOT"
printf 'conductor smoke file operation\n' >"$UPLOAD_FILE"
: >"$SERVER_LOG"
: >"$AGENT_LOG"

if curl -fsS "$BASE_URL/health" >/dev/null 2>&1; then
  echo "Port $PORT already has a responding service at $BASE_URL." >&2
  echo "Set CONDUCTOR_SMOKE_PORT to an unused port, for example:" >&2
  echo "  CONDUCTOR_SMOKE_PORT=18081 $0 ${1:-}" >&2
  exit 1
fi

echo "[1/8] Verifying release checksums"
(
  cd "$RELEASE_DIR"
  sha256sum -c SHA256SUMS
)

echo "[2/8] Starting release server"
CONDUCTOR_DB="$DB_PATH" \
CONDUCTOR_BIND="127.0.0.1:$PORT" \
CONDUCTOR_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
CONDUCTOR_JWT_SECRET="$JWT_SECRET" \
CONDUCTOR_AGENT_TOKEN="$AGENT_TOKEN" \
"$SERVER_BIN" >"$SERVER_LOG" 2>&1 &
server_pid="$!"

for _ in {1..50}; do
  if curl -fsS "$BASE_URL/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -fsS "$BASE_URL/health" | grep -q '"ok":true'

echo "[3/8] Checking embedded web routes"
curl -fsSI "$BASE_URL/" | grep -qi '^content-type: text/html'
curl -fsSI "$BASE_URL/devices" | grep -qi '^content-type: text/html'
if curl -fsSI "$BASE_URL/api/not-real" >/dev/null 2>&1; then
  echo "Unexpected API fallback for /api/not-real" >&2
  exit 1
fi

echo "[4/8] Starting release agent"
CONDUCTOR_SERVER_URL="$BASE_URL" \
CONDUCTOR_AGENT_TOKEN="$AGENT_TOKEN" \
CONDUCTOR_AGENT_NAME="$AGENT_NAME" \
CONDUCTOR_AGENT_ROOT="$AGENT_ROOT" \
"$AGENT_BIN" >"$AGENT_LOG" 2>&1 &
agent_pid="$!"

echo "[5/8] Logging in"
login_body="$(curl -fsS -X POST "$BASE_URL/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}")"
token="$(printf '%s' "$login_body" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
if [[ -z "$token" ]]; then
  echo "Login did not return a token: $login_body" >&2
  exit 1
fi

echo "[6/8] Waiting for agent registration"
devices=""
for _ in {1..50}; do
  devices="$(curl -fsS "$BASE_URL/api/devices" -H "Authorization: Bearer $token")"
  if printf '%s' "$devices" | grep -q "\"hostname\":\"$AGENT_NAME\""; then
    break
  fi
  sleep 0.2
done
device_id="$(printf '%s' "$devices" | sed -n "s/.*\"device_id\":\"\\([^\"]*\\)\".*\"hostname\":\"$AGENT_NAME\".*/\\1/p")"
if [[ -z "$device_id" ]]; then
  echo "Agent did not appear in device list: $devices" >&2
  exit 1
fi

agent_config_log="$(grep "agent config .*agent_name=$AGENT_NAME" "$AGENT_LOG" | tail -n 1 || true)"
if [[ -z "$agent_config_log" ]]; then
  echo "Agent log does not contain expected config line for $AGENT_NAME." >&2
  tail -n 80 "$AGENT_LOG" >&2 2>/dev/null || true
  exit 1
fi
if [[ "$agent_config_log" != *"server_url=ws://127.0.0.1:$PORT/ws/agent"* ]]; then
  echo "Agent config log does not prove normalized server URL: $agent_config_log" >&2
  exit 1
fi
echo "Agent config log observed: $agent_config_log"

echo "[7/8] Checking session, files, and chat"
session_body="$(curl -fsS -X POST "$BASE_URL/api/sessions" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d "{\"device_id\":\"$device_id\"}")"
session_id="$(printf '%s' "$session_body" | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p')"
if [[ -z "$session_id" ]]; then
  echo "Session creation failed: $session_body" >&2
  exit 1
fi

session=""
for _ in {1..50}; do
  session="$(curl -fsS "$BASE_URL/api/sessions/$session_id" -H "Authorization: Bearer $token")"
  if printf '%s' "$session" | grep -q '"status":"active"'; then
    break
  fi
  sleep 0.2
done
printf '%s' "$session" | grep -q '"status":"active"'

curl -fsS "$BASE_URL/api/devices/$device_id/files?path=." \
  -H "Authorization: Bearer $token" | grep -q '"ok":true'
curl -fsS -X POST "$BASE_URL/api/devices/$device_id/files/mkdir" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d '{"path":".","name":"smoke-dir"}' | grep -q '"ok":true'
curl -fsS -X POST "$BASE_URL/api/devices/$device_id/files/upload" \
  -H "Authorization: Bearer $token" \
  -F path=smoke-dir \
  -F "file=@$UPLOAD_FILE;filename=hello.txt" | grep -q '"ok":true'
curl -fsS "$BASE_URL/api/devices/$device_id/files?path=smoke-dir" \
  -H "Authorization: Bearer $token" | grep -q '"name":"hello.txt"'
curl -fsS "$BASE_URL/api/devices/$device_id/files/download?path=smoke-dir/hello.txt" \
  -H "Authorization: Bearer $token" >"$DOWNLOAD_FILE"
cmp -s "$UPLOAD_FILE" "$DOWNLOAD_FILE"
curl -fsS -X DELETE "$BASE_URL/api/devices/$device_id/files?path=smoke-dir/hello.txt" \
  -H "Authorization: Bearer $token" | grep -q '"ok":true'
curl -fsS -X DELETE "$BASE_URL/api/devices/$device_id/files?path=smoke-dir" \
  -H "Authorization: Bearer $token" | grep -q '"ok":true'
curl -fsS -X POST "$BASE_URL/api/sessions/$session_id/messages" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d '{"text":"release smoke hello"}' | grep -q '"text":"release smoke hello"'

echo "[8/8] Closing session"
curl -fsS -X POST "$BASE_URL/api/sessions/$session_id/close" \
  -H "Authorization: Bearer $token" | grep -q '"status":"closed"'

if [[ "${CONDUCTOR_SMOKE_BROWSER:-0}" == "1" ]]; then
  echo "[browser] Checking web console flow"
  CONDUCTOR_SMOKE_BASE_URL="$BASE_URL" \
  CONDUCTOR_SMOKE_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  CONDUCTOR_SMOKE_AGENT_NAME="$AGENT_NAME" \
  node "$RELEASE_DIR/scripts/smoke-web.mjs"
fi

echo "Release smoke test passed for $RELEASE_DIR"
echo "Server log: $SERVER_LOG"
echo "Agent log: $AGENT_LOG"
