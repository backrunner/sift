#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
IOS_DIR="$ROOT_DIR/apps/ios"

echo "Restoring and validating built-in models immediately before xcodebuild:"
"$SCRIPT_DIR/restore_builtin_models.sh"
xcodebuild -version
"$ROOT_DIR/tools/verify_ios_builtin_models.sh" \
  --models-dir "$IOS_DIR/GeneratedModels" \
  --compile

project_file="$IOS_DIR/Sift.xcodeproj/project.pbxproj"
[[ -f "$project_file" ]] || {
  echo "error: generated Xcode project is missing at $project_file" >&2
  exit 1
}

for artifact in SiftSMSClassifier.mlmodel SiftPIIDetector.mlmodelc; do
  grep -q "$artifact" "$project_file" || {
    echo "error: generated Xcode project does not reference $artifact" >&2
    exit 1
  }
done

if grep -q 'SiftPIIDetector.mlpackage' "$project_file"; then
  echo "error: generated Xcode project must bundle the prepared PII mlmodelc, not compile the mlpackage" >&2
  exit 1
fi

echo "Xcode Cloud model preflight passed."
