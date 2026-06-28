#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: build-linux-client-deb.sh <bundle-dir> <output-deb>

Packages an existing Flutter Linux release bundle as an amd64 Debian package.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

BUNDLE_DIR="$1"
OUTPUT_DEB="$2"
ICON_PATH="$ROOT_DIR/client/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png"

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "dpkg-deb is required to build the Linux client package." >&2
  exit 1
fi
if [[ ! -x "$BUNDLE_DIR/conductor_client" ]]; then
  echo "Linux client executable not found: $BUNDLE_DIR/conductor_client" >&2
  exit 1
fi
if [[ ! -x "$BUNDLE_DIR/conductor-agent" ]]; then
  echo "Bundled agent executable not found: $BUNDLE_DIR/conductor-agent" >&2
  exit 1
fi
if [[ ! -f "$ICON_PATH" ]]; then
  echo "Client icon not found: $ICON_PATH" >&2
  exit 1
fi

PACKAGE_VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$ROOT_DIR/client/pubspec.yaml" | head -n 1)"
if [[ -z "$PACKAGE_VERSION" ]]; then
  echo "Unable to read package version from client/pubspec.yaml." >&2
  exit 1
fi

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

install -d \
  "$STAGE_DIR/DEBIAN" \
  "$STAGE_DIR/opt/conductor-client" \
  "$STAGE_DIR/usr/bin" \
  "$STAGE_DIR/usr/share/applications" \
  "$STAGE_DIR/usr/share/icons/hicolor/256x256/apps"
cp -a "$BUNDLE_DIR/." "$STAGE_DIR/opt/conductor-client/"
chmod -R go-w "$STAGE_DIR/opt/conductor-client"
ln -s /opt/conductor-client/conductor_client "$STAGE_DIR/usr/bin/conductor-client"
install -m 0644 "$ICON_PATH" \
  "$STAGE_DIR/usr/share/icons/hicolor/256x256/apps/conductor-client.png"

cat >"$STAGE_DIR/usr/share/applications/conductor-client.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Conductor Client
Comment=Connect this computer to a Conductor server
Exec=/usr/bin/conductor-client
Icon=conductor-client
Terminal=false
Categories=Network;RemoteAccess;
StartupNotify=true
EOF
chmod 0644 "$STAGE_DIR/usr/share/applications/conductor-client.desktop"

INSTALLED_SIZE="$(du -sk --apparent-size "$STAGE_DIR/opt/conductor-client" | awk '{ print $1 }')"
cat >"$STAGE_DIR/DEBIAN/control" <<EOF
Package: conductor-client
Version: $PACKAGE_VERSION
Section: net
Priority: optional
Architecture: amd64
Maintainer: Conductor
Installed-Size: $INSTALLED_SIZE
Depends: libc6, libgcc-s1, libstdc++6, libgtk-3-0 | libgtk-3-0t64, gnome-screenshot, ffmpeg
Description: Conductor controlled desktop client
 Graphical Linux client and bundled agent for connecting a computer to a
 Conductor server.
EOF
chmod 0644 "$STAGE_DIR/DEBIAN/control"

mkdir -p "$(dirname "$OUTPUT_DEB")"
dpkg-deb --build --root-owner-group "$STAGE_DIR" "$OUTPUT_DEB"
echo "Debian package ready: $OUTPUT_DEB"
