#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <linux|macos> <archive-path>" >&2
  exit 2
fi

platform="$1"
archive="$2"

if [[ ! -f "$archive" ]]; then
  echo "Archive not found: $archive" >&2
  exit 1
fi

list="$(tar -tzf "$archive")"

require_entry() {
  local pattern="$1"
  if ! printf '%s\n' "$list" | grep -Eq "$pattern"; then
    echo "Missing archive entry matching: $pattern" >&2
    printf '%s\n' "$list" >&2
    exit 1
  fi
}

case "$platform" in
  linux)
    require_entry '(^|^\./)conductor_client$'
    require_entry '(^|^\./)conductor-agent$'
    require_entry '(^|^\./)data/flutter_assets/'
    require_entry '(^|^\./)lib/libflutter_linux_gtk\.so$'
    ;;
  macos)
    require_entry '^conductor_client\.app/Contents/MacOS/conductor_client$'
    require_entry '^conductor_client\.app/Contents/MacOS/conductor-agent$'
    require_entry '^conductor_client\.app/Contents/Frameworks/'
    require_entry '^conductor_client\.app/Contents/Resources/'
    ;;
  *)
    echo "Unsupported platform: $platform" >&2
    exit 2
    ;;
esac

echo "Client archive verified: $archive"
