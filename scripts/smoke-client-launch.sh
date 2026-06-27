#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <linux|macos> <archive-path> [seconds]" >&2
  exit 2
fi

platform="$1"
archive="$2"
seconds="${3:-8}"

if [[ ! -f "$archive" ]]; then
  echo "Archive not found: $archive" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
client=""
agent=""
client_pid=""
# shellcheck disable=SC2317 # Called by the EXIT trap.
cleanup() {
  if [[ -n "$client_pid" ]] && kill -0 "$client_pid" 2>/dev/null; then
    kill "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
  fi
  if [[ -n "$client" ]]; then
    pkill -f "$client" 2>/dev/null || true
  fi
  if [[ -n "$agent" ]]; then
    pkill -f "$agent" 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

tar -xzf "$archive" -C "$tmp_dir"

case "$platform" in
  linux)
    client="$tmp_dir/conductor_client"
    agent="$tmp_dir/conductor-agent"
    ;;
  macos)
    client="$tmp_dir/conductor_client.app/Contents/MacOS/conductor_client"
    agent="$tmp_dir/conductor_client.app/Contents/MacOS/conductor-agent"
    ;;
  *)
    echo "Unsupported platform: $platform" >&2
    exit 2
    ;;
esac

if [[ ! -x "$client" ]]; then
  echo "Missing or non-executable client binary: $client" >&2
  exit 1
fi
if [[ ! -x "$agent" ]]; then
  echo "Missing or non-executable bundled agent binary: $agent" >&2
  exit 1
fi

run_client=("$client")
if [[ "$platform" == "linux" ]] && command -v xvfb-run >/dev/null 2>&1 && [[ "${CONDUCTOR_CLIENT_SMOKE_NO_XVFB:-0}" != "1" ]]; then
  run_client=(xvfb-run -a "$client")
elif [[ "$platform" == "linux" && -z "${DISPLAY:-}" ]]; then
  echo "DISPLAY is not set and xvfb-run is unavailable." >&2
  exit 1
fi

set +e
CONDUCTOR_CLIENT_SETTINGS_FILE="$tmp_dir/client-settings.json" "${run_client[@]}" &
client_pid="$!"
sleep "$seconds"
if kill -0 "$client_pid" 2>/dev/null; then
  kill "$client_pid" 2>/dev/null || true
  wait "$client_pid" 2>/dev/null
  status=0
  client_pid=""
else
  wait "$client_pid"
  status=$?
  client_pid=""
fi
set -e

if [[ "$status" -eq 0 ]]; then
  echo "Client launch smoke passed after ${seconds}s: $client"
  exit 0
fi

echo "Client exited during launch smoke with status $status: $client" >&2
exit 1
