#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BUNDLE_DIR="$TMP_DIR/bundle"
DEB_PATH="$TMP_DIR/conductor-client-linux-amd64.deb"
EXTRACT_DIR="$TMP_DIR/extracted"

mkdir -p "$BUNDLE_DIR/data/flutter_assets" "$BUNDLE_DIR/lib" "$EXTRACT_DIR"
printf 'client\n' >"$BUNDLE_DIR/conductor_client"
printf 'agent\n' >"$BUNDLE_DIR/conductor-agent"
chmod +x "$BUNDLE_DIR/conductor_client" "$BUNDLE_DIR/conductor-agent"
printf 'asset\n' >"$BUNDLE_DIR/data/flutter_assets/AssetManifest.bin"
printf 'flutter\n' >"$BUNDLE_DIR/lib/libflutter_linux_gtk.so"

"$ROOT_DIR/scripts/build-linux-client-deb.sh" "$BUNDLE_DIR" "$DEB_PATH"
dpkg-deb --info "$DEB_PATH" >/dev/null
dpkg-deb --extract "$DEB_PATH" "$EXTRACT_DIR"

[[ -x "$EXTRACT_DIR/opt/conductor-client/conductor_client" ]]
[[ -x "$EXTRACT_DIR/opt/conductor-client/conductor-agent" ]]
[[ "$(stat -c '%a' "$EXTRACT_DIR/opt/conductor-client/conductor_client")" == "755" ]]
[[ "$(stat -c '%a' "$EXTRACT_DIR/opt/conductor-client/data/flutter_assets/AssetManifest.bin")" == "644" ]]
[[ -L "$EXTRACT_DIR/usr/bin/conductor-client" ]]
[[ "$(readlink "$EXTRACT_DIR/usr/bin/conductor-client")" == "/opt/conductor-client/conductor_client" ]]
[[ -f "$EXTRACT_DIR/usr/share/applications/conductor-client.desktop" ]]
[[ "$(stat -c '%a' "$EXTRACT_DIR/usr/share/applications/conductor-client.desktop")" == "644" ]]
[[ -f "$EXTRACT_DIR/usr/share/icons/hicolor/256x256/apps/conductor-client.png" ]]
dpkg-deb --field "$DEB_PATH" Package | grep -qx 'conductor-client'
dpkg-deb --field "$DEB_PATH" Architecture | grep -qx 'amd64'

echo "Linux client Debian package test passed."
