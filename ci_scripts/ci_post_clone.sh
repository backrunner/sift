#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MODELS_DIR="$ROOT_DIR/apps/ios/GeneratedModels"
VERIFY_SCRIPT="$ROOT_DIR/tools/verify_ios_builtin_models.sh"
LOCK_FILE="$ROOT_DIR/apps/ios/BuiltinModels.lock.json"

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ -d "$MODELS_DIR" ]] && "$VERIFY_SCRIPT" --models-dir "$MODELS_DIR"; then
  echo "Pinned built-in models are already present; download is not needed."
  exit 0
fi

locked_models_url="$(plutil -extract archive.url raw -o - "$LOCK_FILE" 2>/dev/null)" \
  || fail "cannot read archive.url from $LOCK_FILE"
locked_archive_sha="$(plutil -extract archive.sha256 raw -o - "$LOCK_FILE" 2>/dev/null)" \
  || fail "cannot read archive.sha256 from $LOCK_FILE"
models_url="${SIFT_BUILTIN_MODELS_URL:-$locked_models_url}"
expected_sha="${SIFT_BUILTIN_MODELS_SHA256:-$locked_archive_sha}"
[[ -n "$models_url" ]] || fail "built-in model archive URL is empty"
[[ "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]] \
  || fail "built-in model archive SHA-256 must contain 64 hexadecimal characters"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/sift-xcode-cloud-models.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
archive_path="$work_dir/builtin-models.zip"
extract_dir="$work_dir/extracted"
mkdir -p "$extract_dir"

curl_arguments=(
  --fail
  --location
  --silent
  --show-error
  --retry 3
  --retry-all-errors
  --output "$archive_path"
)
if [[ -n "${SIFT_BUILTIN_MODELS_TOKEN:-}" ]]; then
  curl_arguments+=(--header "Authorization: Bearer $SIFT_BUILTIN_MODELS_TOKEN")
fi
curl "${curl_arguments[@]}" "$models_url"

actual_sha="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
normalized_expected_sha="$(printf '%s' "$expected_sha" | tr '[:upper:]' '[:lower:]')"
[[ "$actual_sha" == "$normalized_expected_sha" ]] \
  || fail "built-in model archive SHA-256 mismatch: expected $expected_sha, got $actual_sha"

ditto -x -k "$archive_path" "$extract_dir"
staged_models="$extract_dir/GeneratedModels"
[[ -d "$staged_models" ]] || fail "model archive must contain one top-level GeneratedModels directory"
"$VERIFY_SCRIPT" --models-dir "$staged_models"

mkdir -p "$MODELS_DIR"
ditto "$staged_models" "$MODELS_DIR"
"$VERIFY_SCRIPT" --models-dir "$MODELS_DIR"

echo "Installed pinned built-in models for the Xcode Cloud build."
