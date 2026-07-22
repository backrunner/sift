#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
IOS_DIR="$ROOT_DIR/apps/ios"

echo "Validating built-in models with the selected Xcode toolchain:"
xcodebuild -version
"$ROOT_DIR/tools/verify_ios_builtin_models.sh" \
  --models-dir "$IOS_DIR/GeneratedModels" \
  --compile

project_file="$IOS_DIR/Sift.xcodeproj/project.pbxproj"
[[ -f "$project_file" ]] || {
  echo "error: generated Xcode project is missing at $project_file" >&2
  exit 1
}

for artifact in SiftSMSClassifier.mlmodel SiftPIIDetector.mlpackage; do
  grep -q "$artifact" "$project_file" || {
    echo "error: generated Xcode project does not reference $artifact" >&2
    exit 1
  }
done

echo "Xcode Cloud model preflight passed."
