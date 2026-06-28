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
if [[ ! -f "$archive.sha256" ]]; then
  echo "Archive checksum not found: $archive.sha256" >&2
  exit 1
fi

archive_dir="$(dirname "$archive")"
archive_name="$(basename "$archive")"
(
  cd "$archive_dir"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "$archive_name.sha256"
  else
    shasum -a 256 -c "$archive_name.sha256"
  fi
)

list="$(tar -tzf "$archive")"
verbose_list="$(tar -tvzf "$archive")"
extract_dir=""

cleanup() {
  [[ -z "$extract_dir" ]] || rm -rf "$extract_dir"
}
trap cleanup EXIT

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

extract_archive() {
  if [[ -n "$extract_dir" ]]; then
    return
  fi
  extract_dir="$(mktemp -d)"
  tar -xzf "$archive" -C "$extract_dir"
}

require_extracted_path() {
  local entry="$1"
  if [[ ! -e "$extract_dir/$entry" ]]; then
    echo "Missing or broken extracted archive path: $entry" >&2
    exit 1
  fi
}

require_extracted_executable() {
  local entry="$1"
  require_extracted_path "$entry"
  if [[ ! -x "$extract_dir/$entry" ]]; then
    echo "Extracted archive path is not executable: $entry" >&2
    exit 1
  fi
}

case "$platform" in
  linux)
    require_entry '(^|^\./)conductor_client$'
    require_entry '(^|^\./)conductor-agent$'
    require_executable_entry '(^|^\./)conductor_client$'
    require_executable_entry '(^|^\./)conductor-agent$'
    require_entry '(^|^\./)data/icudtl\.dat$'
    require_entry '(^|^\./)data/flutter_assets/'
    require_entry '(^|^\./)data/flutter_assets/AssetManifest\.bin$'
    require_entry '(^|^\./)data/flutter_assets/FontManifest\.json$'
    require_entry '(^|^\./)data/flutter_assets/NativeAssetsManifest\.json$'
    require_entry '(^|^\./)data/flutter_assets/version\.json$'
    require_entry '(^|^\./)lib/libflutter_linux_gtk\.so$'
    ;;
  macos)
    require_entry '^conductor_client\.app/Contents/MacOS/conductor_client$'
    require_entry '^conductor_client\.app/Contents/MacOS/conductor-agent$'
    require_entry '^conductor_client\.app/Contents/Info\.plist$'
    require_archive_text \
      'conductor_client.app/Contents/Info.plist' \
      'NSMicrophoneUsageDescription'
    require_entry '^conductor_client\.app/Contents/Frameworks/'
    require_entry '^conductor_client\.app/Contents/Frameworks/App\.framework/App$'
    require_entry '^conductor_client\.app/Contents/Frameworks/App\.framework/Resources/?$'
    require_entry '^conductor_client\.app/Contents/Frameworks/FlutterMacOS\.framework/FlutterMacOS$'
    require_entry '^conductor_client\.app/Contents/Resources/'
    extract_archive
    require_extracted_executable 'conductor_client.app/Contents/MacOS/conductor_client'
    require_extracted_executable 'conductor_client.app/Contents/MacOS/conductor-agent'
    require_extracted_executable 'conductor_client.app/Contents/Frameworks/App.framework/App'
    require_extracted_path 'conductor_client.app/Contents/Frameworks/App.framework/Resources/flutter_assets'
    require_extracted_path 'conductor_client.app/Contents/Frameworks/App.framework/Resources/flutter_assets/AssetManifest.bin'
    require_extracted_path 'conductor_client.app/Contents/Frameworks/App.framework/Resources/flutter_assets/FontManifest.json'
    require_extracted_path 'conductor_client.app/Contents/Frameworks/App.framework/Resources/flutter_assets/NativeAssetsManifest.json'
    require_extracted_executable 'conductor_client.app/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS'
    ;;
  *)
    echo "Unsupported platform: $platform" >&2
    exit 2
    ;;
esac

echo "Client archive verified: $archive"
