#!/usr/bin/env bash
set -euo pipefail

archive_path="release/conductor-client-linux-x64.tar.gz"
evidence_dir="artifacts/linux-client-smoke"
skip_client_build=0
skip_server_build=0
require_ci_fields=0
expected_commit=""

usage() {
  cat >&2 <<'EOF'
Usage: validate-linux-client.sh [options]

Options:
  --archive-path <path>      Linux client archive to validate.
  --evidence-dir <path>      Directory for validation-summary.txt and transcript.
  --skip-client-build        Reuse an existing client archive.
  --skip-server-build        Reuse an existing target/debug/conductor-server.
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
    --archive-path)
      require_value "$1" "${2:-}"
      archive_path="${2:-}"
      shift 2
      ;;
    --evidence-dir)
      require_value "$1" "${2:-}"
      evidence_dir="${2:-}"
      shift 2
      ;;
    --skip-client-build)
      skip_client_build=1
      shift
      ;;
    --skip-server-build)
      skip_server_build=1
      shift
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
if [[ "$archive_path" != /* ]]; then
  archive_path="$root_dir/$archive_path"
fi
if [[ "$evidence_dir" != /* ]]; then
  evidence_dir="$root_dir/$evidence_dir"
fi

summary_path="$evidence_dir/validation-summary.txt"
log_path="$evidence_dir/smoke-linux-client-flow.log"
e2e_log_dir="$evidence_dir/logs/client-e2e"
result_written=0

append_summary() {
  printf '%s\n' "$1" >>"$summary_path"
}

append_command_summary() {
  local label="$1"
  shift
  if ! command -v "$1" >/dev/null 2>&1; then
    append_summary "$label=not found"
    return
  fi
  local output
  output="$("$@" 2>&1 || true)"
  if [[ -z "$output" ]]; then
    append_summary "$label="
    return
  fi
  while IFS= read -r line; do
    append_summary "$label=$line"
  done <<<"$output"
}

current_commit() {
  if [[ -n "${GITHUB_SHA:-}" ]]; then
    printf '%s\n' "$GITHUB_SHA"
    return
  fi
  git -C "$root_dir" rev-parse HEAD 2>/dev/null || true
}

write_result() {
  if [[ "$result_written" -eq 0 ]]; then
    append_summary "result=$1"
    result_written=1
  fi
}

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    write_result "failed"
  fi
}
trap cleanup EXIT

mkdir -p "$evidence_dir"
{
  printf 'timestamp=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'repository=%s\n' "$root_dir"
  printf 'archive=%s\n' "$archive_path"
  printf 'skip_client_build=%s\n' "$skip_client_build"
  printf 'skip_server_build=%s\n' "$skip_server_build"
  printf 'commit=%s\n' "$(current_commit)"
  printf 'runner_os=%s\n' "${RUNNER_OS:-}"
  printf 'runner_arch=%s\n' "${RUNNER_ARCH:-}"
  printf 'uname=%s\n' "$(uname -a)"
} >"$summary_path"

append_command_summary "rustc" rustc --version
append_command_summary "cargo" cargo --version
if [[ -n "${FLUTTER_BIN:-}" && -x "${FLUTTER_BIN:-}" ]]; then
  flutter_output="$("$FLUTTER_BIN" --version 2>&1 || true)"
  while IFS= read -r line; do
    append_summary "flutter=$line"
  done <<<"$flutter_output"
else
  append_command_summary "flutter" flutter --version
fi

exec > >(tee "$log_path") 2>&1

echo "Linux client flow smoke"
echo "Repository: $root_dir"
echo "Archive: $archive_path"
echo "Evidence: $evidence_dir"
echo "SkipClientBuild: $skip_client_build"
echo "SkipServerBuild: $skip_server_build"
echo "RequireCiFields: $require_ci_fields"
if [[ -n "$expected_commit" ]]; then
  echo "ExpectedCommit: $expected_commit"
fi

cd "$root_dir"

if [[ "$skip_client_build" -eq 0 ]]; then
  echo ""
  echo "==> Build Linux client package"
  ./scripts/build-client.sh
fi

if [[ "$skip_server_build" -eq 0 ]]; then
  echo ""
  echo "==> Build web assets"
  npm --prefix web ci
  npm --prefix web run build

  echo ""
  echo "==> Build smoke server"
  cargo build -p conductor-server
fi

if [[ ! -f "$archive_path" ]]; then
  echo "Linux client archive not found: $archive_path. Run without --skip-client-build or build the package first." >&2
  exit 1
fi
if [[ ! -x "$root_dir/target/debug/conductor-server" ]]; then
  echo "Smoke server not found: $root_dir/target/debug/conductor-server. Run without --skip-server-build or build the server first." >&2
  exit 1
fi

archive_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
append_summary "archive_sha256=$archive_sha256"
cp "$archive_path.sha256" "$evidence_dir/$(basename "$archive_path").sha256"

echo ""
echo "==> Verify Linux client archive"
./scripts/verify-client-archive.sh linux "$archive_path"

echo ""
echo "==> Smoke launch Linux client"
./scripts/smoke-client-launch.sh linux "$archive_path"

echo ""
echo "==> Smoke register through Linux client"
CONDUCTOR_CLIENT_E2E_EVIDENCE_DIR="$e2e_log_dir" ./scripts/smoke-linux-client-e2e.sh "$archive_path"

echo ""
echo "Linux client flow smoke passed: $archive_path"
write_result "passed"

verify_args=(--evidence-dir "$evidence_dir")
if [[ "$require_ci_fields" -eq 1 ]]; then
  verify_args+=(--require-ci-fields)
fi
if [[ -n "$expected_commit" ]]; then
  verify_args+=(--expected-commit "$expected_commit")
fi
./scripts/verify-linux-smoke-evidence.sh "${verify_args[@]}"

echo "Linux controlled client validation passed."
