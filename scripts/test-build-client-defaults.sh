#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/flutter" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'flutter'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "$FAKE_FLUTTER_LOG"
exit 0
EOF
chmod +x "$fake_bin/flutter"

cat > "$fake_bin/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'cargo'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "$FAKE_CARGO_LOG"
exit 0
EOF
chmod +x "$fake_bin/cargo"

export FAKE_FLUTTER_LOG="$tmp_dir/flutter.log"
export FAKE_CARGO_LOG="$tmp_dir/cargo.log"

mkdir -p \
  "$root_dir/target/release" \
  "$root_dir/client/build/linux/x64/release/bundle/data/flutter_assets"
printf 'agent\n' > "$root_dir/target/release/conductor-agent"
printf 'client\n' > "$root_dir/client/build/linux/x64/release/bundle/conductor_client"
chmod +x \
  "$root_dir/target/release/conductor-agent" \
  "$root_dir/client/build/linux/x64/release/bundle/conductor_client"
printf 'icu\n' > "$root_dir/client/build/linux/x64/release/bundle/data/icudtl.dat"
printf '{}\n' > "$root_dir/client/build/linux/x64/release/bundle/data/flutter_assets/AssetManifest.bin"

server_url="ws://example.test:8080/ws/agent"
agent_token="token with spaces"
agent_name="linux build agent"
agent_root="/tmp/conductor build root"
audio_input="smoke audio input"
interactive_approval="yes"

PATH="$fake_bin:$PATH" FLUTTER_BIN="$fake_bin/flutter" \
  "$root_dir/scripts/build-client.sh" \
    --server-url "$server_url" \
    --agent-token "$agent_token" \
    --agent-name "$agent_name" \
    --agent-root "$agent_root" \
    --audio-input "$audio_input" \
    --interactive-approval "$interactive_approval" \
  > "$tmp_dir/build-client.log"

require_log_line() {
  local pattern="$1"
  if ! grep -Fq -- "$pattern" "$FAKE_FLUTTER_LOG"; then
    echo "Missing Flutter argument pattern: $pattern" >&2
    cat "$FAKE_FLUTTER_LOG" >&2
    exit 1
  fi
}

require_log_line $'flutter\tconfig\t--enable-linux-desktop'
require_log_line $'--dart-define\tCONDUCTOR_DEFAULT_SERVER_URL=ws://example.test:8080/ws/agent'
require_log_line $'--dart-define\tCONDUCTOR_DEFAULT_AGENT_TOKEN=token with spaces'
require_log_line $'--dart-define\tCONDUCTOR_DEFAULT_AGENT_NAME=linux build agent'
require_log_line $'--dart-define\tCONDUCTOR_DEFAULT_AGENT_ROOT=/tmp/conductor build root'
require_log_line $'--dart-define\tCONDUCTOR_DEFAULT_AUDIO_INPUT=smoke audio input'
require_log_line $'--dart-define\tCONDUCTOR_DEFAULT_INTERACTIVE_APPROVAL=yes'

: >"$FAKE_FLUTTER_LOG"
env_server_url="wss://env.example.test/ws/agent"
env_agent_token="env token"
env_agent_name="env build agent"
env_agent_root="/tmp/env conductor root"
env_audio_input="env audio input"
env_interactive_approval="off"

PATH="$fake_bin:$PATH" \
  FLUTTER_BIN="$fake_bin/flutter" \
  CONDUCTOR_DEFAULT_SERVER_URL="$env_server_url" \
  CONDUCTOR_DEFAULT_AGENT_TOKEN="$env_agent_token" \
  CONDUCTOR_DEFAULT_AGENT_NAME="$env_agent_name" \
  CONDUCTOR_DEFAULT_AGENT_ROOT="$env_agent_root" \
  CONDUCTOR_DEFAULT_AUDIO_INPUT="$env_audio_input" \
  CONDUCTOR_DEFAULT_INTERACTIVE_APPROVAL="$env_interactive_approval" \
  "$root_dir/scripts/build-client.sh" > "$tmp_dir/build-client-env.log"

require_log_line $'--dart-define\tCONDUCTOR_DEFAULT_SERVER_URL=wss://env.example.test/ws/agent'
require_log_line $'--dart-define\tCONDUCTOR_DEFAULT_AGENT_TOKEN=env token'
require_log_line $'--dart-define\tCONDUCTOR_DEFAULT_AGENT_NAME=env build agent'
require_log_line $'--dart-define\tCONDUCTOR_DEFAULT_AGENT_ROOT=/tmp/env conductor root'
require_log_line $'--dart-define\tCONDUCTOR_DEFAULT_AUDIO_INPUT=env audio input'
require_log_line $'--dart-define\tCONDUCTOR_DEFAULT_INTERACTIVE_APPROVAL=off'

if [[ ! -f "$root_dir/release/conductor-client-linux-x64.tar.gz" ]]; then
  echo "Linux client archive was not created." >&2
  exit 1
fi
if [[ ! -f "$root_dir/release/conductor-client-linux-x64.tar.gz.sha256" ]]; then
  echo "Linux client archive checksum was not created." >&2
  exit 1
fi
(
  cd "$root_dir/release"
  sha256sum -c conductor-client-linux-x64.tar.gz.sha256 >/dev/null
)

echo "Build client defaults test passed."
