#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <linux> <archive-path> [seconds]" >&2
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
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

tar -xzf "$archive" -C "$tmp_dir"

case "$platform" in
  linux)
    client="$tmp_dir/conductor_client"
    agent="$tmp_dir/conductor-agent"
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
if command -v xvfb-run >/dev/null 2>&1 && [[ "${CONDUCTOR_CLIENT_SMOKE_NO_XVFB:-0}" != "1" ]]; then
  run_client=(xvfb-run -a "$client")
elif [[ -z "${DISPLAY:-}" ]]; then
  echo "DISPLAY is not set and xvfb-run is unavailable." >&2
  exit 1
fi

set +e
timeout "${seconds}s" "${run_client[@]}"
status=$?
set -e

if [[ "$status" -eq 124 ]]; then
  echo "Client launch smoke passed after ${seconds}s: $client"
  exit 0
fi

echo "Client exited during launch smoke with status $status: $client" >&2
exit 1
