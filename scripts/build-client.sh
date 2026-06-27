#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-/home/flex/Code/flutter/bin/flutter}"
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

Builds the controlled desktop client for the current host platform.

Options:
  --server-url <url>             Default Server URL baked into the client.
  --agent-token <token>          Default Agent Token baked into the client.
  --agent-name <name>            Default Agent Name baked into the client.
  --agent-root <path>            Default file root baked into the client.
  --audio-input <input>          Default audio input baked into the client.
  --interactive-approval <bool>  Default local approval setting.
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

if [[ ! -x "$FLUTTER_BIN" ]]; then
  echo "Flutter executable not found: $FLUTTER_BIN" >&2
  echo "Set FLUTTER_BIN=/path/to/flutter and retry." >&2
  exit 1
fi

case "$(uname -s)" in
  Linux*)
    PLATFORM="linux"
    AGENT_NAME="conductor-agent"
    BUNDLE_DIR="$ROOT_DIR/client/build/linux/x64/release/bundle"
    ARCHIVE_PATH="$RELEASE_DIR/conductor-client-linux-x64.tar.gz"
    ARCHIVE_CWD="$BUNDLE_DIR"
    ARCHIVE_ITEM="."
    ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    PLATFORM="windows"
    AGENT_NAME="conductor-agent.exe"
    BUNDLE_DIR="$ROOT_DIR/client/build/windows/x64/runner/Release"
    ARCHIVE_PATH="$RELEASE_DIR/conductor-client-windows-x64.tar.gz"
    ARCHIVE_CWD="$BUNDLE_DIR"
    ARCHIVE_ITEM="."
    ;;
  Darwin*)
    PLATFORM="macos"
    AGENT_NAME="conductor-agent"
    APP_DIR="$ROOT_DIR/client/build/macos/Build/Products/Release/conductor_client.app"
    BUNDLE_DIR="$APP_DIR/Contents/MacOS"
    ARCHIVE_PATH="$RELEASE_DIR/conductor-client-macos.tar.gz"
    ARCHIVE_CWD="$(dirname "$APP_DIR")"
    ARCHIVE_ITEM="$(basename "$APP_DIR")"
    ;;
  *)
    echo "Unsupported host platform: $(uname -s)" >&2
    exit 1
    ;;
esac

echo "[1/4] Building Rust agent"
cargo build --manifest-path "$ROOT_DIR/Cargo.toml" --release -p conductor-agent

echo "[2/4] Building Flutter client for $PLATFORM"
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
  "$FLUTTER_BIN" build "$PLATFORM" --release "${FLUTTER_DEFINES[@]}"
)

echo "[3/4] Copying agent into client bundle"
mkdir -p "$BUNDLE_DIR"
cp "$ROOT_DIR/target/release/$AGENT_NAME" "$BUNDLE_DIR/$AGENT_NAME"

echo "[4/4] Creating distributable archive"
mkdir -p "$RELEASE_DIR"
tar -czf "$ARCHIVE_PATH" -C "$ARCHIVE_CWD" "$ARCHIVE_ITEM"

echo "Client bundle ready: $BUNDLE_DIR"
echo "Agent binary copied to: $BUNDLE_DIR/$AGENT_NAME"
echo "Archive ready: $ARCHIVE_PATH"
