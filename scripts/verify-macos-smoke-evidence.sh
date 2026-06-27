#!/usr/bin/env bash
set -euo pipefail

evidence_dir="artifacts/macos-client-smoke"
require_ci_fields=0
expected_commit=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --evidence-dir)
      evidence_dir="${2:-}"
      shift 2
      ;;
    --require-ci-fields)
      require_ci_fields=1
      shift
      ;;
    --expected-commit)
      expected_commit="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$evidence_dir" != /* ]]; then
  evidence_dir="$root_dir/$evidence_dir"
fi

summary_path="$evidence_dir/validation-summary.txt"
log_path="$evidence_dir/smoke-macos-client-flow.log"

if [[ ! -f "$summary_path" ]]; then
  echo "Missing macOS smoke evidence summary: $summary_path" >&2
  exit 1
fi
if [[ ! -f "$log_path" ]]; then
  echo "Missing macOS smoke transcript: $log_path" >&2
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
    echo "Missing macOS smoke evidence field: $key" >&2
    exit 1
  fi
}

for key in \
  timestamp \
  repository \
  archive \
  uname \
  rustc \
  cargo \
  flutter \
  xcodebuild \
  archive_sha256 \
  result; do
  require_field "$key"
done

if [[ "$require_ci_fields" -eq 1 ]]; then
  for key in commit runner_os runner_arch; do
    require_field "$key"
  done
fi

if [[ -n "$expected_commit" ]]; then
  actual_commit="$(summary_value commit)"
  if [[ "$actual_commit" != "$expected_commit" ]]; then
    echo "macOS smoke evidence commit mismatch. Expected: $expected_commit Actual: $actual_commit" >&2
    exit 1
  fi
fi

for key in rustc cargo flutter xcodebuild; do
  if [[ "$(summary_value "$key")" == "not found" ]]; then
    echo "macOS smoke evidence reports missing tool: $key" >&2
    exit 1
  fi
done

result="$(summary_value result)"
if [[ "$result" != "passed" ]]; then
  echo "macOS smoke evidence result is not passed: $result" >&2
  exit 1
fi

archive_sha256="$(summary_value archive_sha256)"
if [[ ! "$archive_sha256" =~ ^[a-f0-9]{64}$ ]]; then
  echo "macOS smoke evidence archive_sha256 is invalid: $archive_sha256" >&2
  exit 1
fi

archive_path="$(summary_value archive)"
if [[ -f "$archive_path" ]]; then
  actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$archive_sha256" ]]; then
    echo "macOS smoke evidence archive hash mismatch. Summary: $archive_sha256 Actual: $actual_sha256" >&2
    exit 1
  fi
else
  echo "macOS smoke archive is not present for hash recheck: $archive_path"
fi

if ! grep -q "macOS client flow smoke passed" "$log_path"; then
  echo "macOS smoke transcript does not contain the success marker." >&2
  exit 1
fi

echo "macOS smoke evidence verified: $evidence_dir"
