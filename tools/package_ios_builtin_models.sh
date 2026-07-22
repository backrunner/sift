#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_DIR="$ROOT_DIR/apps/ios/GeneratedModels"
LOCK_FILE="$ROOT_DIR/apps/ios/BuiltinModels.lock.json"
OUTPUT_PATH=""

usage() {
  cat <<'USAGE'
Usage: tools/package_ios_builtin_models.sh [--models-dir PATH] [--lock-file PATH] [--output PATH]

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
    --models-dir)
      shift
      [[ $# -gt 0 ]] || fail "--models-dir requires a path"
      MODELS_DIR="$1"
      ;;
    --lock-file)
      shift
      [[ $# -gt 0 ]] || fail "--lock-file requires a path"
      LOCK_FILE="$1"
      ;;
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

RELEASE="$(plutil -extract release raw -o - "$LOCK_FILE")"
ARCHIVE_URL="$(plutil -extract archive.url raw -o - "$LOCK_FILE")"
if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$ROOT_DIR/build/ios-models/SiftBuiltinModels-$RELEASE.zip"
fi

"$ROOT_DIR/tools/verify_ios_builtin_models.sh" \
  --models-dir "$MODELS_DIR" \
  --lock-file "$LOCK_FILE" \
  --compile

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

# ZIP metadata must be stable so the archive SHA identifies model content,
# rather than the time this command happened to run.
find "$staging_dir/GeneratedModels" -exec touch -t 200001010000 {} +

mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUTPUT_PATH"
ditto -c -k --norsrc --keepParent "$staging_dir/GeneratedModels" "$OUTPUT_PATH"

archive_sha="$(shasum -a 256 "$OUTPUT_PATH" | awk '{print $1}')"
echo "Created $OUTPUT_PATH"
echo "SIFT_BUILTIN_MODELS_URL=$ARCHIVE_URL"
echo "SIFT_BUILTIN_MODELS_SHA256=$archive_sha"
