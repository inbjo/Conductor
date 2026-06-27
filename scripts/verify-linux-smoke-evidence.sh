#!/usr/bin/env bash
set -euo pipefail

evidence_dir="artifacts/linux-client-smoke"
require_ci_fields=0
expected_commit=""

usage() {
  cat >&2 <<'EOF'
Usage: verify-linux-smoke-evidence.sh [options]

Options:
  --evidence-dir <path>      Directory containing validation-summary.txt and smoke-linux-client-flow.log.
  --require-ci-fields        Require runner_os and runner_arch in evidence.
  --expected-commit <sha>    Require evidence commit to match this SHA.
  -h, --help                 Show this help.
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
    --evidence-dir)
      require_value "$1" "${2:-}"
      evidence_dir="${2:-}"
      shift 2
      ;;
    --require-ci-fields)
      require_ci_fields=1
      shift
      ;;
    --expected-commit)
      require_value "$1" "${2:-}"
      expected_commit="${2:-}"
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

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$evidence_dir" != /* ]]; then
  evidence_dir="$root_dir/$evidence_dir"
fi

summary_path="$evidence_dir/validation-summary.txt"
log_path="$evidence_dir/smoke-linux-client-flow.log"
e2e_server_log="$evidence_dir/logs/client-e2e/server.log"
e2e_client_log="$evidence_dir/logs/client-e2e/client.log"
e2e_settings_file="$evidence_dir/logs/client-e2e/client-settings.json"

if [[ ! -f "$summary_path" ]]; then
  echo "Missing Linux smoke evidence summary: $summary_path" >&2
  exit 1
fi
if [[ ! -f "$log_path" ]]; then
  echo "Missing Linux smoke transcript: $log_path" >&2
  exit 1
fi
if [[ ! -f "$e2e_server_log" ]]; then
  echo "Missing Linux client e2e server log: $e2e_server_log" >&2
  exit 1
fi
if [[ ! -f "$e2e_client_log" ]]; then
  echo "Missing Linux client e2e client log: $e2e_client_log" >&2
  exit 1
fi
if [[ ! -f "$e2e_settings_file" ]]; then
  echo "Missing Linux client e2e settings file: $e2e_settings_file" >&2
  exit 1
fi

summary_value() {
  local key="$1"
  sed -n "s/^$key=//p" "$summary_path" | tail -n 1
}

require_field() {
  local key="$1"
  local value
  value="$(summary_value "$key")"
  if [[ -z "$value" ]]; then
    echo "Missing Linux smoke evidence field: $key" >&2
    exit 1
  fi
}

for key in \
  timestamp \
  repository \
  archive \
  commit \
  uname \
  rustc \
  cargo \
  flutter \
  archive_sha256 \
  result; do
  require_field "$key"
done

if [[ "$require_ci_fields" -eq 1 ]]; then
  for key in runner_os runner_arch; do
    require_field "$key"
  done
fi

if [[ -n "$expected_commit" ]]; then
  actual_commit="$(summary_value commit)"
  if [[ "$actual_commit" != "$expected_commit" ]]; then
    echo "Linux smoke evidence commit mismatch. Expected: $expected_commit Actual: $actual_commit" >&2
    exit 1
  fi
fi

for key in rustc cargo flutter; do
  if [[ "$(summary_value "$key")" == "not found" ]]; then
    echo "Linux smoke evidence reports missing tool: $key" >&2
    exit 1
  fi
done

result="$(summary_value result)"
if [[ "$result" != "passed" ]]; then
  echo "Linux smoke evidence result is not passed: $result" >&2
  exit 1
fi

archive_sha256="$(summary_value archive_sha256)"
if [[ ! "$archive_sha256" =~ ^[a-f0-9]{64}$ ]]; then
  echo "Linux smoke evidence archive_sha256 is invalid: $archive_sha256" >&2
  exit 1
fi

archive_path="$(summary_value archive)"
if [[ -f "$archive_path" ]]; then
  actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$archive_sha256" ]]; then
    echo "Linux smoke evidence archive hash mismatch. Summary: $archive_sha256 Actual: $actual_sha256" >&2
    exit 1
  fi
  if [[ ! -f "$archive_path.sha256" ]]; then
    echo "Linux smoke evidence archive checksum sidecar is missing: $archive_path.sha256" >&2
    exit 1
  fi
  sidecar_sha256="$(awk '{print $1; exit}' "$archive_path.sha256")"
  if [[ "$sidecar_sha256" != "$archive_sha256" ]]; then
    echo "Linux smoke evidence archive sidecar hash mismatch. Summary: $archive_sha256 Sidecar: $sidecar_sha256" >&2
    exit 1
  fi
else
  echo "Linux smoke archive is not present for hash recheck: $archive_path"
fi

if ! grep -q "Linux client flow smoke passed" "$log_path"; then
  echo "Linux smoke transcript does not contain the success marker." >&2
  exit 1
fi
if ! grep -q "Agent config log observed" "$log_path"; then
  echo "Linux smoke transcript does not prove client-to-agent runtime config propagation." >&2
  exit 1
fi
if ! grep -q "Agent diagnostics observed" "$log_path"; then
  echo "Linux smoke transcript does not prove diagnostics command execution." >&2
  exit 1
fi
if ! grep -q "agent config " "$e2e_client_log"; then
  echo "Linux client e2e client log does not contain the agent config line." >&2
  exit 1
fi
if ! grep -q "agent config .*root=.*agent-root .*audio_input=smoke-audio-input" "$e2e_client_log"; then
  echo "Linux client e2e client log does not prove file root and audio input propagation." >&2
  exit 1
fi
if ! grep -q "\[diagnostics\] conductor-agent" "$e2e_client_log"; then
  echo "Linux client e2e client log does not contain diagnostics output." >&2
  exit 1
fi
if ! grep -q '"serverUrl": "ws://127\.0\.0\.1:.*\/ws\/agent"' "$e2e_settings_file"; then
  echo "Linux client e2e settings file does not contain the normalized serverUrl." >&2
  exit 1
fi
if ! grep -q '"agentName": "linux-client-e2e-agent-' "$e2e_settings_file"; then
  echo "Linux client e2e settings file does not contain the expected agentName." >&2
  exit 1
fi
if ! grep -q '"agentRoot": ".*/agent-root"' "$e2e_settings_file"; then
  echo "Linux client e2e settings file does not contain the expected agentRoot." >&2
  exit 1
fi
if ! grep -q '"audioInput": "smoke-audio-input"' "$e2e_settings_file"; then
  echo "Linux client e2e settings file does not contain the expected audioInput." >&2
  exit 1
fi
if ! grep -q '"interactiveApproval": false' "$e2e_settings_file"; then
  echo "Linux client e2e settings file does not contain interactiveApproval=false." >&2
  exit 1
fi

echo "Linux smoke evidence verified: $evidence_dir"
