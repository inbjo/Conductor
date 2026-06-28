#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${FLUTTER_BIN:-}" ]]; then
  if command -v flutter >/dev/null 2>&1; then
    FLUTTER_BIN="$(command -v flutter)"
  else
    FLUTTER_BIN="/home/flex/Code/flutter/bin/flutter"
  fi
fi
RELEASE_DIR="$ROOT_DIR/release"
DEFAULT_SERVER_URL="${CONDUCTOR_DEFAULT_SERVER_URL:-}"
DEFAULT_AGENT_TOKEN="${CONDUCTOR_DEFAULT_AGENT_TOKEN:-}"
DEFAULT_AGENT_NAME="${CONDUCTOR_DEFAULT_AGENT_NAME:-}"
DEFAULT_AGENT_ROOT="${CONDUCTOR_DEFAULT_AGENT_ROOT:-}"
DEFAULT_AUDIO_INPUT="${CONDUCTOR_DEFAULT_AUDIO_INPUT:-}"
DEFAULT_INTERACTIVE_APPROVAL="${CONDUCTOR_DEFAULT_INTERACTIVE_APPROVAL:-}"

usage() {
  cat >&2 <<'EOF'
Usage: build-client.sh [options]

Builds the controlled desktop client for Linux or macOS on the current host.
Use scripts/build-client.ps1 for the Windows zip package.

Options:
  --server-url <url>             Default Server URL baked into the client.
  --agent-token <token>          Default Agent Token baked into the client.
  --agent-name <name>            Default Agent Name baked into the client.
  --agent-root <path>            Default file root baked into the client.
  --audio-input <input>          Default audio input baked into the client.
  --interactive-approval <bool>  Default local approval setting: 1/0, true/false, yes/no, on/off.
  -h, --help                     Show this help.

Environment:
  FLUTTER_BIN                    Flutter executable path.
  CONDUCTOR_DEFAULT_*            Build default values used when options are omitted.
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "Missing value for $option" >&2
    usage
    exit 2
  fi
}

validate_bool() {
  local option="$1"
  local value="$2"
  local normalized_value
  normalized_value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$normalized_value" in
    1|0|true|false|yes|no|on|off)
      ;;
    *)
      echo "Invalid value for $option: $value" >&2
      echo "Use one of: 1, 0, true, false, yes, no, on, off." >&2
      exit 2
      ;;
  esac
}

write_archive_checksum() {
  local archive_path="$1"
  local archive_dir
  local archive_name
  archive_dir="$(dirname "$archive_path")"
  archive_name="$(basename "$archive_path")"
  (
    cd "$archive_dir"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$archive_name"
    else
      shasum -a 256 "$archive_name"
    fi > "$archive_name.sha256"
  )
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-url)
      require_value "$1" "${2:-}"
      DEFAULT_SERVER_URL="${2:-}"
      shift 2
      ;;
    --agent-token)
      require_value "$1" "${2:-}"
      DEFAULT_AGENT_TOKEN="${2:-}"
      shift 2
      ;;
    --agent-name)
      require_value "$1" "${2:-}"
      DEFAULT_AGENT_NAME="${2:-}"
      shift 2
      ;;
    --agent-root)
      require_value "$1" "${2:-}"
      DEFAULT_AGENT_ROOT="${2:-}"
      shift 2
      ;;
    --audio-input)
      require_value "$1" "${2:-}"
      DEFAULT_AUDIO_INPUT="${2:-}"
      shift 2
      ;;
    --interactive-approval)
      require_value "$1" "${2:-}"
      validate_bool "$1" "${2:-}"
      DEFAULT_INTERACTIVE_APPROVAL="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -n "$DEFAULT_INTERACTIVE_APPROVAL" ]]; then
  validate_bool "CONDUCTOR_DEFAULT_INTERACTIVE_APPROVAL" "$DEFAULT_INTERACTIVE_APPROVAL"
fi

if [[ ! -x "$FLUTTER_BIN" ]]; then
  echo "Flutter executable not found: $FLUTTER_BIN" >&2
  echo "Set FLUTTER_BIN=/path/to/flutter and retry." >&2
  exit 1
fi

case "$(uname -s)" in
  Linux*)
    PLATFORM="linux"
    AGENT_BIN_NAME="conductor-agent"
    BUNDLE_DIR="$ROOT_DIR/client/build/linux/x64/release/bundle"
    ARCHIVE_PATH="$RELEASE_DIR/conductor-client-linux-x64.tar.gz"
    ARCHIVE_CWD="$BUNDLE_DIR"
    ARCHIVE_ITEM="."
    ;;
  Darwin*)
    PLATFORM="macos"
    AGENT_BIN_NAME="conductor-agent"
    APP_DIR="$ROOT_DIR/client/build/macos/Build/Products/Release/conductor_client.app"
    BUNDLE_DIR="$APP_DIR/Contents/MacOS"
    ARCHIVE_PATH="$RELEASE_DIR/conductor-client-macos.tar.gz"
    ARCHIVE_CWD="$(dirname "$APP_DIR")"
    ARCHIVE_ITEM="$(basename "$APP_DIR")"
    ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    echo "Use scripts/build-client.ps1 to build the Windows client zip package." >&2
    exit 2
    ;;
  *)
    echo "Unsupported host platform: $(uname -s)" >&2
    exit 1
    ;;
esac

AGENT_BIN="$ROOT_DIR/target/release/$AGENT_BIN_NAME"

echo "[1/5] Enabling Flutter $PLATFORM desktop target"
"$FLUTTER_BIN" config "--enable-$PLATFORM-desktop"

echo "[2/5] Building Rust agent"
cargo clean --manifest-path "$ROOT_DIR/Cargo.toml" --release -p conductor-agent
cargo build --manifest-path "$ROOT_DIR/Cargo.toml" --release -p conductor-agent

echo "[3/5] Building Flutter client for $PLATFORM"
FLUTTER_DEFINES=()
if [[ -n "$DEFAULT_SERVER_URL" ]]; then
  FLUTTER_DEFINES+=(--dart-define "CONDUCTOR_DEFAULT_SERVER_URL=$DEFAULT_SERVER_URL")
fi
if [[ -n "$DEFAULT_AGENT_TOKEN" ]]; then
  FLUTTER_DEFINES+=(--dart-define "CONDUCTOR_DEFAULT_AGENT_TOKEN=$DEFAULT_AGENT_TOKEN")
fi
if [[ -n "$DEFAULT_AGENT_NAME" ]]; then
  FLUTTER_DEFINES+=(--dart-define "CONDUCTOR_DEFAULT_AGENT_NAME=$DEFAULT_AGENT_NAME")
fi
if [[ -n "$DEFAULT_AGENT_ROOT" ]]; then
  FLUTTER_DEFINES+=(--dart-define "CONDUCTOR_DEFAULT_AGENT_ROOT=$DEFAULT_AGENT_ROOT")
fi
if [[ -n "$DEFAULT_AUDIO_INPUT" ]]; then
  FLUTTER_DEFINES+=(--dart-define "CONDUCTOR_DEFAULT_AUDIO_INPUT=$DEFAULT_AUDIO_INPUT")
fi
if [[ -n "$DEFAULT_INTERACTIVE_APPROVAL" ]]; then
  FLUTTER_DEFINES+=(
    --dart-define
    "CONDUCTOR_DEFAULT_INTERACTIVE_APPROVAL=$DEFAULT_INTERACTIVE_APPROVAL"
  )
fi
(
  cd "$ROOT_DIR/client"
  if [[ "${#FLUTTER_DEFINES[@]}" -gt 0 ]]; then
    "$FLUTTER_BIN" build "$PLATFORM" --release "${FLUTTER_DEFINES[@]}"
  else
    "$FLUTTER_BIN" build "$PLATFORM" --release
  fi
)

echo "[4/5] Copying agent into client bundle"
mkdir -p "$BUNDLE_DIR"
cp "$AGENT_BIN" "$BUNDLE_DIR/$AGENT_BIN_NAME"

echo "[5/5] Creating distributable archive"
mkdir -p "$RELEASE_DIR"
tar -czf "$ARCHIVE_PATH" -C "$ARCHIVE_CWD" "$ARCHIVE_ITEM"
write_archive_checksum "$ARCHIVE_PATH"

echo "Client bundle ready: $BUNDLE_DIR"
echo "Agent binary copied to: $BUNDLE_DIR/$AGENT_BIN_NAME"
echo "Archive ready: $ARCHIVE_PATH"
echo "Archive checksum: $ARCHIVE_PATH.sha256"
