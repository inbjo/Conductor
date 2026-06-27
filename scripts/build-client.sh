#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-/home/flex/Code/flutter/bin/flutter}"
RELEASE_DIR="$ROOT_DIR/release"

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
(
  cd "$ROOT_DIR/client"
  "$FLUTTER_BIN" build "$PLATFORM" --release
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
