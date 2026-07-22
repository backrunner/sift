#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_DIR="$ROOT_DIR/apps/ios/GeneratedModels"
LOCK_FILE="$ROOT_DIR/apps/ios/BuiltinModels.lock.json"
RELEASE="$(plutil -extract release raw -o - "$LOCK_FILE")"
ARCHIVE_URL="$(plutil -extract archive.url raw -o - "$LOCK_FILE")"
OUTPUT_PATH="$ROOT_DIR/build/ios-models/SiftBuiltinModels-$RELEASE.zip"

usage() {
  cat <<'USAGE'
Usage: tools/package_ios_builtin_models.sh [--output PATH]

Creates the immutable ZIP consumed by Xcode Cloud. The command prints the
archive SHA-256 that must be stored in SIFT_BUILTIN_MODELS_SHA256.
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      shift
      [[ $# -gt 0 ]] || fail "--output requires a path"
      OUTPUT_PATH="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
  shift
done

"$ROOT_DIR/tools/verify_ios_builtin_models.sh" --models-dir "$MODELS_DIR" --compile

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/sift-ios-models.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "$staging_dir/GeneratedModels"

artifacts=(
  SiftSMSClassifier.mlmodel
  SiftSMSClassifier.manifest.json
  SiftPIIDetector.mlpackage
  SiftPIIDetector.vocab.txt
  SiftPIIDetector.manifest.json
)
for artifact in "${artifacts[@]}"; do
  ditto "$MODELS_DIR/$artifact" "$staging_dir/GeneratedModels/$artifact"
done

mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUTPUT_PATH"
ditto -c -k --norsrc --keepParent "$staging_dir/GeneratedModels" "$OUTPUT_PATH"

archive_sha="$(shasum -a 256 "$OUTPUT_PATH" | awk '{print $1}')"
echo "Created $OUTPUT_PATH"
echo "SIFT_BUILTIN_MODELS_URL=$ARCHIVE_URL"
echo "SIFT_BUILTIN_MODELS_SHA256=$archive_sha"
