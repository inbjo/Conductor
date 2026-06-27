#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

commit="test-client-evidence-commit"
artifacts="$tmp_dir/artifacts"
verified="$tmp_dir/verified"

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

mkdir -p \
  "$artifacts/linux-client-smoke-evidence/logs/client-e2e" \
  "$artifacts/windows-client-smoke-evidence/logs/agent-e2e" \
  "$artifacts/windows-client-smoke-evidence/logs/client-e2e" \
  "$artifacts/macos-client-smoke-evidence/logs/client-e2e"

printf 'synthetic windows archive\n' > "$tmp_dir/windows.zip"
write_sha256 "$tmp_dir/windows.zip"
windows_archive_sha256="$(awk '{print $1; exit}' "$tmp_dir/windows.zip.sha256")"
cp "$tmp_dir/windows.zip.sha256" "$artifacts/windows-client-smoke-evidence/windows.zip.sha256"
cat > "$artifacts/linux-client-smoke-evidence/missing-linux.tar.gz.sha256" <<'EOF'
1111111111111111111111111111111111111111111111111111111111111111  missing-linux.tar.gz
EOF
cat > "$artifacts/macos-client-smoke-evidence/missing-macos.tar.gz.sha256" <<'EOF'
3333333333333333333333333333333333333333333333333333333333333333  missing-macos.tar.gz
EOF

cat > "$artifacts/linux-client-smoke-evidence/validation-summary.txt" <<EOF
timestamp=2026-06-27T00:00:00Z
repository=/tmp
archive=/tmp/missing-linux.tar.gz
commit=$commit
uname=Linux
rustc=rustc 1
cargo=cargo 1
flutter=Flutter 3
archive_sha256=1111111111111111111111111111111111111111111111111111111111111111
result=passed
EOF
cat > "$artifacts/linux-client-smoke-evidence/smoke-linux-client-flow.log" <<'EOF'
Linux client flow smoke passed
Client server URL input: http://127.0.0.1:18082
Agent config log observed
Agent diagnostics observed
EOF
cat > "$artifacts/linux-client-smoke-evidence/logs/client-e2e/server.log" <<'EOF'
server
EOF
cat > "$artifacts/linux-client-smoke-evidence/logs/client-e2e/client.log" <<'EOF'
agent config server_url=ws://127.0.0.1:18082/ws/agent root=/tmp/linux/agent-root agent_name=linux-client-e2e-agent-demo audio_input=smoke-audio-input
[diagnostics] conductor-agent
EOF
cat > "$artifacts/linux-client-smoke-evidence/logs/client-e2e/client-settings.json" <<'EOF'
{
  "serverUrl": "ws://127.0.0.1:18082/ws/agent",
  "agentName": "linux-client-e2e-agent-demo",
  "agentRoot": "/tmp/linux/agent-root",
  "audioInput": "smoke-audio-input",
  "interactiveApproval": false
}
EOF

cat > "$artifacts/windows-client-smoke-evidence/validation-summary.txt" <<EOF
timestamp=2026-06-27T00:00:00Z
repository=/tmp
archive=$tmp_dir/windows.zip
commit=$commit
powershell=PowerShell 7
rustc=rustc 1
cargo=cargo 1
flutter=Flutter 3
archive_sha256=$windows_archive_sha256
result=passed
EOF
cat > "$artifacts/windows-client-smoke-evidence/smoke-windows-client-flow.log" <<'EOF'
Windows client flow smoke passed
Client server URL input: http://127.0.0.1:18081
Agent config log observed
Agent diagnostics observed
EOF
cat > "$artifacts/windows-client-smoke-evidence/logs/agent-e2e/server.log" <<'EOF'
server
EOF
cat > "$artifacts/windows-client-smoke-evidence/logs/agent-e2e/agent.log" <<'EOF'
agent config server_url=ws://127.0.0.1:18081/ws/agent root=C:\Temp\agent-root agent_name=windows-client-e2e-demo audio_input=smoke-audio-input
EOF
cat > "$artifacts/windows-client-smoke-evidence/logs/client-e2e/server.log" <<'EOF'
server
EOF
cat > "$artifacts/windows-client-smoke-evidence/logs/client-e2e/client.log" <<'EOF'
agent config server_url=ws://127.0.0.1:18081/ws/agent root=C:\Temp\agent-root agent_name=windows-client-e2e-demo audio_input=smoke-audio-input
[diagnostics] conductor-agent
EOF
cat > "$artifacts/windows-client-smoke-evidence/logs/client-e2e/client-settings.json" <<'EOF'
{
  "serverUrl": "ws://127.0.0.1:18081/ws/agent",
  "agentName": "windows-client-e2e-demo",
  "agentRoot": "C:\\Temp\\agent-root",
  "audioInput": "smoke-audio-input",
  "interactiveApproval": false
}
EOF

cat > "$artifacts/macos-client-smoke-evidence/validation-summary.txt" <<EOF
timestamp=2026-06-27T00:00:00Z
repository=/tmp
archive=/tmp/missing-macos.tar.gz
commit=$commit
uname=Darwin
rustc=rustc 1
cargo=cargo 1
flutter=Flutter 3
xcodebuild=Xcode 16
archive_sha256=3333333333333333333333333333333333333333333333333333333333333333
result=passed
EOF
cat > "$artifacts/macos-client-smoke-evidence/smoke-macos-client-flow.log" <<'EOF'
macOS client flow smoke passed
Client server URL input: http://127.0.0.1:18083
Agent config log observed
Agent diagnostics observed
EOF
cat > "$artifacts/macos-client-smoke-evidence/logs/client-e2e/server.log" <<'EOF'
server
EOF
cat > "$artifacts/macos-client-smoke-evidence/logs/client-e2e/client.log" <<'EOF'
agent config server_url=ws://127.0.0.1:18083/ws/agent root=/tmp/macos/agent-root agent_name=macos-client-e2e-agent-demo audio_input=smoke-audio-input
[diagnostics] conductor-agent
EOF
cat > "$artifacts/macos-client-smoke-evidence/logs/client-e2e/client-settings.json" <<'EOF'
{
  "serverUrl": "ws://127.0.0.1:18083/ws/agent",
  "agentName": "macos-client-e2e-agent-demo",
  "agentRoot": "/tmp/macos/agent-root",
  "audioInput": "smoke-audio-input",
  "interactiveApproval": false
}
EOF

"$root_dir/scripts/validate-client-evidence.sh" \
  --evidence-root "$artifacts" \
  --expected-commit "$commit" \
  --write-summary "$verified"

for file in \
  aggregate-summary.txt \
  linux-validation-summary.txt \
  windows-validation-summary.txt \
  macos-validation-summary.txt; do
  if [[ ! -f "$verified/$file" ]]; then
    echo "Missing verified summary file: $file" >&2
    exit 1
  fi
done

grep -q "^commit=$commit$" "$verified/aggregate-summary.txt"
grep -q '^linux_result=passed$' "$verified/aggregate-summary.txt"
grep -q '^windows_result=passed$' "$verified/aggregate-summary.txt"
grep -q '^macos_result=passed$' "$verified/aggregate-summary.txt"
grep -q "^windows_archive_sha256=$windows_archive_sha256$" "$verified/aggregate-summary.txt"

mv \
  "$artifacts/windows-client-smoke-evidence/windows.zip.sha256" \
  "$artifacts/windows-client-smoke-evidence/windows.zip.sha256.bak"
if "$root_dir/scripts/validate-client-evidence.sh" \
  --evidence-root "$artifacts" \
  --platform windows \
  --expected-commit "$commit" >"$tmp_dir/evidence-missing-sidecar.log" 2>&1; then
  echo "Expected missing smoke evidence archive sidecar to fail." >&2
  exit 1
fi
grep -q "Windows smoke evidence archive checksum sidecar" "$tmp_dir/evidence-missing-sidecar.log"
mv \
  "$artifacts/windows-client-smoke-evidence/windows.zip.sha256.bak" \
  "$artifacts/windows-client-smoke-evidence/windows.zip.sha256"

sed -i 's/^commit=.*/commit=other-test-client-evidence-commit/' \
  "$artifacts/windows-client-smoke-evidence/validation-summary.txt"
if "$root_dir/scripts/validate-client-evidence.sh" \
  --evidence-root "$artifacts" \
  --write-summary "$tmp_dir/should-fail" >"$tmp_dir/evidence-mismatch.log" 2>&1; then
  echo "Expected mixed commit evidence to fail." >&2
  exit 1
fi
grep -q "Client smoke evidence commit mismatch" "$tmp_dir/evidence-mismatch.log"

echo "Client evidence summary test passed."
