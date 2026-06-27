#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"
LABEL="${TARGET:-$(rustc -vV | sed -n 's/^host: //p')}"
STAGE_DIR="$ROOT_DIR/release/conductor-$LABEL"
CARGO_ARGS=(--release -p conductor-server -p conductor-agent)

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no)" ]]; then
  echo "Refusing to build a release from a dirty worktree. Commit or stash tracked changes first." >&2
  exit 1
fi

if [[ -n "$TARGET" ]]; then
  CARGO_ARGS+=(--target "$TARGET")
  BINARY_DIR="$ROOT_DIR/target/$TARGET/release"
else
  BINARY_DIR="$ROOT_DIR/target/release"
fi

SUFFIX=""
if [[ "$LABEL" == *windows* ]]; then
  SUFFIX=".exe"
fi

echo "[1/4] Building web assets"
npm --prefix "$ROOT_DIR/web" ci
npm --prefix "$ROOT_DIR/web" run build

echo "[2/4] Building Rust binaries for $LABEL"
cargo build --manifest-path "$ROOT_DIR/Cargo.toml" "${CARGO_ARGS[@]}"

echo "[3/4] Staging release files"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/bin" "$STAGE_DIR/docs" "$STAGE_DIR/source"
cp "$BINARY_DIR/conductor-server$SUFFIX" "$STAGE_DIR/bin/"
cp "$BINARY_DIR/conductor-agent$SUFFIX" "$STAGE_DIR/bin/"
cp "$ROOT_DIR/README.md" "$STAGE_DIR/"
cp "$ROOT_DIR/docs/demo.md" "$STAGE_DIR/docs/"
cp "$ROOT_DIR/docs/plan.md" "$STAGE_DIR/docs/"
git -C "$ROOT_DIR" archive HEAD | tar -x -C "$STAGE_DIR/source"

echo "[4/4] Creating archive"
tar -czf "$ROOT_DIR/release/conductor-$LABEL.tar.gz" -C "$ROOT_DIR/release" "conductor-$LABEL"
echo "Release ready: $ROOT_DIR/release/conductor-$LABEL.tar.gz"
