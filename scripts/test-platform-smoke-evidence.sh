#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

commit="test-platform-smoke-evidence-commit"

write_platform_evidence() {
  local platform="$1"
  local evidence_dir="$2"
  local archive_path="$3"
  local archive_sha256="$4"
  local agent_name_prefix="$5"

  mkdir -p "$evidence_dir/logs/client-e2e"
  cat > "$evidence_dir/$(basename "$archive_path").sha256" <<EOF
$archive_sha256  $(basename "$archive_path")
EOF

  cat > "$evidence_dir/validation-summary.txt" <<EOF
timestamp=2026-06-28T00:00:00Z
repository=$root_dir
archive=$archive_path
commit=$commit
runner_os=$platform
runner_arch=X64
uname=$platform synthetic
rustc=rustc 1
cargo=cargo 1
flutter=Flutter 3
archive_sha256=$archive_sha256
result=passed
EOF
  if [[ "$platform" == "macOS" ]]; then
    printf 'xcodebuild=Xcode 16\n' >> "$evidence_dir/validation-summary.txt"
  fi

  cat > "$evidence_dir/smoke-${platform,,}-client-flow.log" <<EOF
$platform client flow smoke passed
Client server URL input: http://127.0.0.1:18082
Agent config log observed
Agent diagnostics observed
EOF
  cat > "$evidence_dir/logs/client-e2e/server.log" <<'EOF'
server
EOF
  cat > "$evidence_dir/logs/client-e2e/client.log" <<EOF
agent config server_url=ws://127.0.0.1:18082/ws/agent root=/tmp/$platform/agent-root agent_name=$agent_name_prefix-demo audio_input=smoke-audio-input
[diagnostics] conductor-agent
EOF
  cat > "$evidence_dir/logs/client-e2e/client-settings.json" <<EOF
{
  "serverUrl": "ws://127.0.0.1:18082/ws/agent",
  "agentName": "$agent_name_prefix-demo",
  "agentRoot": "/tmp/$platform/agent-root",
  "audioInput": "smoke-audio-input",
  "interactiveApproval": false
}
EOF
}

expect_failure() {
  local expected_text="$1"
  shift
  local failure_log="$tmp_dir/failure.log"

  if "$@" >"$failure_log" 2>&1; then
    echo "Expected command to fail: $expected_text" >&2
    exit 1
  fi
  if ! grep -q "$expected_text" "$failure_log"; then
    echo "Failure did not contain expected text: $expected_text" >&2
    cat "$failure_log" >&2
    exit 1
  fi
}

linux_evidence="$tmp_dir/linux-client-smoke"
linux_archive="/tmp/missing-linux-smoke.tar.gz"
linux_sha256="1111111111111111111111111111111111111111111111111111111111111111"
write_platform_evidence "Linux" "$linux_evidence" "$linux_archive" "$linux_sha256" "linux-client-e2e-agent"

"$root_dir/scripts/verify-linux-smoke-evidence.sh" \
  --evidence-dir "$linux_evidence" \
  --require-ci-fields \
  --expected-commit "$commit"

mv "$linux_evidence/$(basename "$linux_archive").sha256" "$linux_evidence/$(basename "$linux_archive").sha256.bak"
expect_failure "Linux smoke evidence archive checksum sidecar" \
  "$root_dir/scripts/verify-linux-smoke-evidence.sh" \
  --evidence-dir "$linux_evidence" \
  --expected-commit "$commit"
mv "$linux_evidence/$(basename "$linux_archive").sha256.bak" "$linux_evidence/$(basename "$linux_archive").sha256"

expect_failure "Linux smoke evidence commit mismatch" \
  "$root_dir/scripts/verify-linux-smoke-evidence.sh" \
  --evidence-dir "$linux_evidence" \
  --expected-commit "other-$commit"

macos_evidence="$tmp_dir/macos-client-smoke"
macos_archive="/tmp/missing-macos-smoke.tar.gz"
macos_sha256="3333333333333333333333333333333333333333333333333333333333333333"
write_platform_evidence "macOS" "$macos_evidence" "$macos_archive" "$macos_sha256" "macos-client-e2e-agent"

"$root_dir/scripts/verify-macos-smoke-evidence.sh" \
  --evidence-dir "$macos_evidence" \
  --require-ci-fields \
  --expected-commit "$commit"

mv "$macos_evidence/$(basename "$macos_archive").sha256" "$macos_evidence/$(basename "$macos_archive").sha256.bak"
expect_failure "macOS smoke evidence archive checksum sidecar" \
  "$root_dir/scripts/verify-macos-smoke-evidence.sh" \
  --evidence-dir "$macos_evidence" \
  --expected-commit "$commit"
mv "$macos_evidence/$(basename "$macos_archive").sha256.bak" "$macos_evidence/$(basename "$macos_archive").sha256"

expect_failure "macOS smoke evidence commit mismatch" \
  "$root_dir/scripts/verify-macos-smoke-evidence.sh" \
  --evidence-dir "$macos_evidence" \
  --expected-commit "other-$commit"

echo "Platform smoke evidence verifier test passed."
