#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_DIR="$ROOT_DIR/apps/ios/GeneratedModels"
LOCK_FILE="$ROOT_DIR/apps/ios/BuiltinModels.lock.json"
COMPILE_MODELS=0

usage() {
  cat <<'USAGE'
Usage: tools/verify_ios_builtin_models.sh [--models-dir PATH] [--compile]

Validates the exact Classic and PII artifacts pinned by
apps/ios/BuiltinModels.lock.json. --compile additionally asks the selected
Xcode toolchain to compile both Core ML artifacts.
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
    --compile)
      COMPILE_MODELS=1
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

[[ -f "$LOCK_FILE" ]] || fail "model lock not found at $LOCK_FILE"
[[ -d "$MODELS_DIR" ]] || fail "built-in model directory not found at $MODELS_DIR"

required_artifacts=(
  SiftSMSClassifier.mlmodel
  SiftSMSClassifier.manifest.json
  SiftPIIDetector.mlpackage
  SiftPIIDetector.vocab.txt
  SiftPIIDetector.manifest.json
)

for artifact in "${required_artifacts[@]}"; do
  [[ -e "$MODELS_DIR/$artifact" ]] || fail "required built-in model artifact is missing: $artifact"
done

if find "$MODELS_DIR" -maxdepth 1 \( -name 'SiftSignalModel*' -o -name 'SiftTransformerClassifier*' \) -print -quit | grep -q .; then
  fail "Premium Transformer artifacts must not be bundled in GeneratedModels"
fi

json_value() {
  local file="$1"
  local key_path="$2"
  plutil -extract "$key_path" raw -o - "$file" 2>/dev/null \
    || fail "cannot read $key_path from $file"
}

file_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

directory_sha256() {
  local directory="$1"
  (
    cd "$directory"
    while IFS= read -r relative_path; do
      printf '%s' "$relative_path"
      command cat "$relative_path"
    done < <(find . -type f -print | sed 's#^\./##' | LC_ALL=C sort)
  ) | shasum -a 256 | awk '{print $1}'
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local description="$3"
  [[ "$actual" == "$expected" ]] || fail "$description mismatch: expected $expected, got $actual"
}

classic_model="$MODELS_DIR/SiftSMSClassifier.mlmodel"
classic_manifest="$MODELS_DIR/SiftSMSClassifier.manifest.json"
pii_package="$MODELS_DIR/SiftPIIDetector.mlpackage"
pii_vocabulary="$MODELS_DIR/SiftPIIDetector.vocab.txt"
pii_manifest="$MODELS_DIR/SiftPIIDetector.manifest.json"

classic_version="$(json_value "$LOCK_FILE" classic.version)"
classic_model_sha="$(json_value "$LOCK_FILE" classic.modelSHA256)"
classic_manifest_sha="$(json_value "$LOCK_FILE" classic.manifestSHA256)"
pii_version="$(json_value "$LOCK_FILE" pii.version)"
pii_package_sha="$(json_value "$LOCK_FILE" pii.packageSHA256)"
pii_vocabulary_sha="$(json_value "$LOCK_FILE" pii.vocabularySHA256)"
pii_manifest_sha="$(json_value "$LOCK_FILE" pii.manifestSHA256)"

assert_equal "$classic_model_sha" "$(file_sha256 "$classic_model")" "Classic model SHA-256"
assert_equal "$classic_manifest_sha" "$(file_sha256 "$classic_manifest")" "Classic manifest SHA-256"
assert_equal "$pii_package_sha" "$(directory_sha256 "$pii_package")" "PII model package SHA-256"
assert_equal "$pii_vocabulary_sha" "$(file_sha256 "$pii_vocabulary")" "PII vocabulary SHA-256"
assert_equal "$pii_manifest_sha" "$(file_sha256 "$pii_manifest")" "PII manifest SHA-256"

assert_equal "$classic_version" "$(json_value "$classic_manifest" version)" "Classic model version"
assert_equal "$classic_model_sha" "$(json_value "$classic_manifest" sha256)" "Classic manifest model SHA-256"
assert_equal "SiftSMSClassifier.mlmodel" "$(json_value "$classic_manifest" modelArtifact)" "Classic model artifact name"
assert_equal "$pii_version" "$(json_value "$pii_manifest" version)" "PII model version"
assert_equal "$pii_package_sha" "$(json_value "$pii_manifest" sha256)" "PII manifest package SHA-256"
assert_equal "SiftPIIDetector.mlpackage" "$(json_value "$pii_manifest" modelArtifact)" "PII model artifact name"
assert_equal "SiftPIIDetector.vocab.txt" "$(json_value "$pii_manifest" vocabularyArtifact)" "PII vocabulary artifact name"

if [[ "$COMPILE_MODELS" -eq 1 ]]; then
  command -v xcrun >/dev/null 2>&1 || fail "xcrun is required for --compile"
  compile_dir="$(mktemp -d "${TMPDIR:-/tmp}/sift-coreml-compile.XXXXXX")"
  trap 'rm -rf "$compile_dir"' EXIT

  xcrun coremlcompiler compile "$classic_model" "$compile_dir/classic" \
    --platform ios \
    --deployment-target 18.0
  xcrun coremlcompiler compile "$pii_package" "$compile_dir/pii" \
    --platform ios \
    --deployment-target 18.0

  [[ -d "$compile_dir/classic/SiftSMSClassifier.mlmodelc" ]] \
    || fail "Core ML compiler did not emit the Classic compiled model"
  [[ -d "$compile_dir/pii/SiftPIIDetector.mlmodelc" ]] \
    || fail "Core ML compiler did not emit the PII compiled model"
fi

echo "Verified iOS built-in models: $classic_version and $pii_version."
