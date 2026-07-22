#!/usr/bin/env bash
set -euo pipefail

action="${CI_XCODEBUILD_ACTION:-}"
archive_path="${CI_ARCHIVE_PATH:-}"

if [[ -z "$archive_path" || ! -d "$archive_path" ]]; then
  if [[ "$action" == "archive" ]]; then
    echo "error: CI_ARCHIVE_PATH is unavailable after an archive action" >&2
    exit 1
  fi
  echo "No archive produced for action ${action:-unknown}; bundle model checks skipped."
  exit 0
fi

app_bundle="$archive_path/Products/Applications/SiftApp.app"
extension_bundle="$app_bundle/PlugIns/MessageFilterExtension.appex"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_path() {
  [[ -e "$1" ]] || fail "archive is missing $1"
}

require_path "$app_bundle/SiftSMSClassifier.mlmodelc"
require_path "$app_bundle/SiftSMSClassifier.manifest.json"
require_path "$app_bundle/SiftPIIDetector.mlmodelc"
require_path "$app_bundle/SiftPIIDetector.vocab.txt"
require_path "$app_bundle/SiftPIIDetector.manifest.json"
require_path "$extension_bundle/SiftSMSClassifier.mlmodelc"
require_path "$extension_bundle/SiftSMSClassifier.manifest.json"

if find "$extension_bundle" -name 'SiftPIIDetector*' -print -quit | grep -q .; then
  fail "PII model must be bundled only in the main app"
fi
if find "$app_bundle" \( -name 'SiftSignalModel*' -o -name 'SiftTransformerClassifier*' \) -print -quit | grep -q .; then
  fail "Premium Transformer must be downloaded on demand and is present in the archive"
fi

echo "Archive contains the pinned Classic and PII models in the correct bundles."
