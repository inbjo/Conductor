#!/usr/bin/env bash
set -euo pipefail

evidence_root="artifacts"
platform="all"
require_ci_fields=0
expected_commit=""

usage() {
  cat >&2 <<'EOF'
Usage: validate-client-evidence.sh [options]

Options:
  --evidence-root <path>     Root directory containing platform evidence directories.
  --platform <name>          all, linux, windows, or macos.
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
    --evidence-root)
      require_value "$1" "${2:-}"
      evidence_root="${2:-}"
      shift 2
      ;;
    --platform)
      require_value "$1" "${2:-}"
      platform="${2:-}"
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
if [[ "$evidence_root" != /* ]]; then
  evidence_root="$root_dir/$evidence_root"
fi

summary_value() {
  local summary_path="$1"
  local key="$2"
  sed -n "s/^$key=//p" "$summary_path" | tail -n 1
}

require_summary_field() {
  local label="$1"
  local summary_path="$2"
  local key="$3"
  local value
  value="$(summary_value "$summary_path" "$key")"
  if [[ -z "$value" ]]; then
    echo "Missing $label smoke evidence field: $key" >&2
    exit 1
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

require_file() {
  local label="$1"
  local path="$2"
  if [[ ! -f "$path" ]]; then
    echo "Missing $label file: $path" >&2
    exit 1
  fi
}

require_grep() {
  local label="$1"
  local pattern="$2"
  local path="$3"
  if ! grep -q "$pattern" "$path"; then
    echo "$label does not contain required marker: $pattern" >&2
    exit 1
  fi
}

platform_evidence_dir() {
  local platform_name="$1"
  local path_dir="$evidence_root/$platform_name-client-smoke"
  local artifact_dir="$evidence_root/$platform_name-client-smoke-evidence"

  if [[ -d "$path_dir" ]]; then
    printf '%s\n' "$path_dir"
    return
  fi
  if [[ -d "$artifact_dir" ]]; then
    printf '%s\n' "$artifact_dir"
    return
  fi

  printf '%s\n' "$path_dir"
}

verify_text_evidence() {
  local label="$1"
  local evidence_dir="$2"
  local log_name="$3"
  local success_marker="$4"
  shift 4
  local required_tools=("$@")

  local summary_path="$evidence_dir/validation-summary.txt"
  local log_path="$evidence_dir/$log_name"

  if [[ ! -f "$summary_path" ]]; then
    echo "Missing $label smoke evidence summary: $summary_path" >&2
    exit 1
  fi
  if [[ ! -f "$log_path" ]]; then
    echo "Missing $label smoke transcript: $log_path" >&2
    exit 1
  fi

  for key in timestamp repository archive commit archive_sha256 result; do
    require_summary_field "$label" "$summary_path" "$key"
  done
  for key in "${required_tools[@]}"; do
    require_summary_field "$label" "$summary_path" "$key"
  done

  if [[ "$require_ci_fields" -eq 1 ]]; then
    for key in runner_os runner_arch; do
      require_summary_field "$label" "$summary_path" "$key"
    done
  fi

  if [[ -n "$expected_commit" ]]; then
    local actual_commit
    actual_commit="$(summary_value "$summary_path" commit)"
    if [[ "$actual_commit" != "$expected_commit" ]]; then
      echo "$label smoke evidence commit mismatch. Expected: $expected_commit Actual: $actual_commit" >&2
      exit 1
    fi
  fi

  for key in "${required_tools[@]}"; do
    if [[ "$(summary_value "$summary_path" "$key")" == "not found" ]]; then
      echo "$label smoke evidence reports missing tool: $key" >&2
      exit 1
    fi
  done

  local result
  result="$(summary_value "$summary_path" result)"
  if [[ "$result" != "passed" ]]; then
    echo "$label smoke evidence result is not passed: $result" >&2
    exit 1
  fi

  local archive_sha256
  archive_sha256="$(summary_value "$summary_path" archive_sha256)"
  if [[ ! "$archive_sha256" =~ ^[a-f0-9]{64}$ ]]; then
    echo "$label smoke evidence archive_sha256 is invalid: $archive_sha256" >&2
    exit 1
  fi

  local archive_path
  archive_path="$(summary_value "$summary_path" archive)"
  if [[ -f "$archive_path" ]]; then
    local actual_sha256
    actual_sha256="$(sha256_file "$archive_path")"
    if [[ "$actual_sha256" != "$archive_sha256" ]]; then
      echo "$label smoke evidence archive hash mismatch. Summary: $archive_sha256 Actual: $actual_sha256" >&2
      exit 1
    fi
  else
    echo "$label smoke archive is not present for hash recheck: $archive_path"
  fi

  if ! grep -q "$success_marker" "$log_path"; then
    echo "$label smoke transcript does not contain the success marker." >&2
    exit 1
  fi
  if ! grep -q "Agent config log observed" "$log_path"; then
    echo "$label smoke transcript does not prove client-to-agent runtime config propagation." >&2
    exit 1
  fi
  if ! grep -q "Agent diagnostics observed" "$log_path"; then
    echo "$label smoke transcript does not prove diagnostics command execution." >&2
    exit 1
  fi

}

verify_linux() {
  local evidence_dir
  evidence_dir="$(platform_evidence_dir linux)"
  local args=(--evidence-dir "$evidence_dir")
  if [[ "$require_ci_fields" -eq 1 ]]; then
    args+=(--require-ci-fields)
  fi
  if [[ -n "$expected_commit" ]]; then
    args+=(--expected-commit "$expected_commit")
  fi
  "$root_dir/scripts/verify-linux-smoke-evidence.sh" \
    "${args[@]}"
}

verify_macos() {
  local evidence_dir
  evidence_dir="$(platform_evidence_dir macos)"
  local args=(--evidence-dir "$evidence_dir")
  if [[ "$require_ci_fields" -eq 1 ]]; then
    args+=(--require-ci-fields)
  fi
  if [[ -n "$expected_commit" ]]; then
    args+=(--expected-commit "$expected_commit")
  fi
  "$root_dir/scripts/verify-macos-smoke-evidence.sh" \
    "${args[@]}"
}

verify_windows() {
  local evidence_dir
  evidence_dir="$(platform_evidence_dir windows)"
  verify_text_evidence \
    "Windows" \
    "$evidence_dir" \
    "smoke-windows-client-flow.log" \
    "Windows client flow smoke passed" \
    powershell \
    rustc \
    cargo \
    flutter

  local agent_e2e_server_log="$evidence_dir/logs/agent-e2e/server.log"
  local agent_e2e_agent_log="$evidence_dir/logs/agent-e2e/agent.log"
  local client_e2e_server_log="$evidence_dir/logs/client-e2e/server.log"
  local client_e2e_client_log="$evidence_dir/logs/client-e2e/client.log"
  local client_e2e_settings_file="$evidence_dir/logs/client-e2e/client-settings.json"

  require_file "Windows agent e2e server log" "$agent_e2e_server_log"
  require_file "Windows agent e2e agent log" "$agent_e2e_agent_log"
  require_file "Windows client e2e server log" "$client_e2e_server_log"
  require_file "Windows client e2e client log" "$client_e2e_client_log"
  require_file "Windows client e2e settings file" "$client_e2e_settings_file"
  require_grep "Windows agent e2e agent log" "agent config " "$agent_e2e_agent_log"
  require_grep "Windows client e2e client log" "agent config " "$client_e2e_client_log"
  require_grep "Windows client e2e client log" "\[diagnostics\] conductor-agent" "$client_e2e_client_log"
  require_grep "Windows client e2e settings file" '"serverUrl": "ws://127\.0\.0\.1:.*\/ws\/agent"' "$client_e2e_settings_file"
  require_grep "Windows client e2e settings file" '"agentName": "windows-client-e2e-' "$client_e2e_settings_file"
  require_grep "Windows client e2e settings file" '"interactiveApproval": false' "$client_e2e_settings_file"

  echo "Windows smoke evidence verified: $evidence_dir"
}

case "$platform" in
  all)
    verify_linux
    verify_windows
    verify_macos
    ;;
  linux)
    verify_linux
    ;;
  windows)
    verify_windows
    ;;
  macos)
    verify_macos
    ;;
  *)
    echo "Unsupported platform: $platform" >&2
    exit 2
    ;;
esac

echo "Client smoke evidence validation passed for platform=$platform"
