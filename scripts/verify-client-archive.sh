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
verbose_list="$(tar -tvzf "$archive")"

require_entry() {
  local pattern="$1"
  if ! printf '%s\n' "$list" | grep -Eq "$pattern"; then
    echo "Missing archive entry matching: $pattern" >&2
    printf '%s\n' "$list" >&2
    exit 1
  fi
}

require_executable_entry() {
  local pattern="$1"
  local entry
  entry="$(printf '%s\n' "$verbose_list" | awk -v pattern="$pattern" '$NF ~ pattern { print; exit }')"
  if [[ -z "$entry" ]]; then
    echo "Missing executable archive entry matching: $pattern" >&2
    printf '%s\n' "$verbose_list" >&2
    exit 1
  fi
  local mode="${entry%% *}"
  if [[ "${mode:3:1}${mode:6:1}${mode:9:1}" != *x* ]]; then
    echo "Archive entry is not executable: $entry" >&2
    exit 1
  fi
}

require_archive_text() {
  local entry="$1"
  local pattern="$2"
  if ! tar -xOzf "$archive" "$entry" | grep -q "$pattern"; then
    echo "Archive entry $entry does not contain required text: $pattern" >&2
    exit 1
  fi
}

case "$platform" in
  linux)
    require_entry '(^|^\./)conductor_client$'
    require_entry '(^|^\./)conductor-agent$'
    require_executable_entry '(^|^\./)conductor_client$'
    require_executable_entry '(^|^\./)conductor-agent$'
    require_entry '(^|^\./)data/flutter_assets/'
    require_entry '(^|^\./)lib/libflutter_linux_gtk\.so$'
    ;;
  macos)
    require_entry '^conductor_client\.app/Contents/MacOS/conductor_client$'
    require_entry '^conductor_client\.app/Contents/MacOS/conductor-agent$'
    require_executable_entry '^conductor_client\.app/Contents/MacOS/conductor_client$'
    require_executable_entry '^conductor_client\.app/Contents/MacOS/conductor-agent$'
    require_entry '^conductor_client\.app/Contents/Info\.plist$'
    require_archive_text \
      'conductor_client.app/Contents/Info.plist' \
      'NSMicrophoneUsageDescription'
    require_entry '^conductor_client\.app/Contents/Frameworks/'
    require_entry '^conductor_client\.app/Contents/Resources/'
    ;;
  *)
    echo "Unsupported platform: $platform" >&2
    exit 2
    ;;
esac

echo "Client archive verified: $archive"
