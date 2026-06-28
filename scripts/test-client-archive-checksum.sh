#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

write_sha256() {
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

expect_failure() {
  local expected="$1"
  shift
  local log_path="$tmp_dir/failure.log"
  if "$@" >"$log_path" 2>&1; then
    echo "Expected command to fail: $*" >&2
    exit 1
  fi
  if ! grep -q "$expected" "$log_path"; then
    echo "Failure did not contain expected text: $expected" >&2
    cat "$log_path" >&2
    exit 1
  fi
}

linux_dir="$tmp_dir/linux"
mkdir -p "$linux_dir/data/flutter_assets" "$linux_dir/lib"
printf 'client\n' > "$linux_dir/conductor_client"
printf 'agent\n' > "$linux_dir/conductor-agent"
chmod +x "$linux_dir/conductor_client" "$linux_dir/conductor-agent"
printf 'icu\n' > "$linux_dir/data/icudtl.dat"
printf 'asset\n' > "$linux_dir/data/flutter_assets/AssetManifest.bin"
printf 'font\n' > "$linux_dir/data/flutter_assets/FontManifest.json"
printf 'native\n' > "$linux_dir/data/flutter_assets/NativeAssetsManifest.json"
printf 'version\n' > "$linux_dir/data/flutter_assets/version.json"
printf 'flutter\n' > "$linux_dir/lib/libflutter_linux_gtk.so"
tar -czf "$tmp_dir/linux-client.tar.gz" -C "$linux_dir" .
write_sha256 "$tmp_dir/linux-client.tar.gz"
"$root_dir/scripts/verify-client-archive.sh" linux "$tmp_dir/linux-client.tar.gz"

mv "$tmp_dir/linux-client.tar.gz.sha256" "$tmp_dir/linux-client.tar.gz.sha256.bak"
expect_failure \
  "Archive checksum not found" \
  "$root_dir/scripts/verify-client-archive.sh" linux "$tmp_dir/linux-client.tar.gz"
mv "$tmp_dir/linux-client.tar.gz.sha256.bak" "$tmp_dir/linux-client.tar.gz.sha256"
printf '0000000000000000000000000000000000000000000000000000000000000000  linux-client.tar.gz\n' \
  > "$tmp_dir/linux-client.tar.gz.sha256"
expect_failure \
  "FAILED" \
  "$root_dir/scripts/verify-client-archive.sh" linux "$tmp_dir/linux-client.tar.gz"

macos_dir="$tmp_dir/macos/conductor_client.app"
mkdir -p \
  "$macos_dir/Contents/MacOS" \
  "$macos_dir/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets" \
  "$macos_dir/Contents/Frameworks/FlutterMacOS.framework/Versions/A" \
  "$macos_dir/Contents/Resources"
printf 'client\n' > "$macos_dir/Contents/MacOS/conductor_client"
printf 'agent\n' > "$macos_dir/Contents/MacOS/conductor-agent"
printf 'app\n' > "$macos_dir/Contents/Frameworks/App.framework/Versions/A/App"
printf 'flutter\n' > "$macos_dir/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS"
ln -s A "$macos_dir/Contents/Frameworks/App.framework/Versions/Current"
ln -s Versions/Current/App "$macos_dir/Contents/Frameworks/App.framework/App"
ln -s Versions/Current/Resources "$macos_dir/Contents/Frameworks/App.framework/Resources"
ln -s A "$macos_dir/Contents/Frameworks/FlutterMacOS.framework/Versions/Current"
ln -s Versions/Current/FlutterMacOS "$macos_dir/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS"
chmod +x \
  "$macos_dir/Contents/MacOS/conductor_client" \
  "$macos_dir/Contents/MacOS/conductor-agent"
chmod 0644 \
  "$macos_dir/Contents/Frameworks/App.framework/Versions/A/App" \
  "$macos_dir/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS"
cat > "$macos_dir/Contents/Info.plist" <<'EOF'
<plist><dict><key>NSMicrophoneUsageDescription</key><string>Microphone</string></dict></plist>
EOF
printf 'asset\n' > "$macos_dir/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/AssetManifest.bin"
printf 'font\n' > "$macos_dir/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/FontManifest.json"
printf 'native\n' > "$macos_dir/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/NativeAssetsManifest.json"
tar -czf "$tmp_dir/macos-client.tar.gz" -C "$tmp_dir/macos" conductor_client.app
write_sha256 "$tmp_dir/macos-client.tar.gz"
"$root_dir/scripts/verify-client-archive.sh" macos "$tmp_dir/macos-client.tar.gz"

echo "Client archive checksum test passed."
