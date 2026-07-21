#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --device <udid> --candidate <directory> --output <directory> [--allow-provisioning-updates]" >&2
  exit 2
}

device=""
candidate=""
output=""
allow_provisioning_updates=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || usage
      device="$2"
      shift 2
      ;;
    --candidate)
      [[ $# -ge 2 ]] || usage
      candidate="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || usage
      output="$2"
      shift 2
      ;;
    --allow-provisioning-updates)
      allow_provisioning_updates=1
      shift
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$device" && -n "$candidate" && -n "$output" ]] || usage
[[ -d "$candidate" ]] || { echo "error: candidate directory not found: $candidate" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
ios_root="$repo_root/apps/ios"
candidate="$(cd "$candidate" && pwd)"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
derived_data="$output/DerivedData"
result_bundle="$output/TransformerDeviceTests.xcresult"

provisioning_arguments=()
if [[ "$allow_provisioning_updates" -eq 1 ]]; then
  provisioning_arguments+=("-allowProvisioningUpdates")
fi

cd "$ios_root"
xcodegen generate

xcodebuild \
  -project Sift.xcodeproj \
  -scheme TransformerDeviceTests \
  -configuration Release \
  -destination "platform=iOS,id=$device" \
  -derivedDataPath "$derived_data" \
  EXCLUDED_SOURCE_FILE_NAMES=SiftPIIDetector.mlpackage \
  "${provisioning_arguments[@]}" \
  build-for-testing

app_path="$derived_data/Build/Products/Release-iphoneos/SiftApp.app"
[[ -d "$app_path" ]] || { echo "error: benchmark host app was not built" >&2; exit 1; }

xcrun devicectl device install app \
  --device "$device" \
  "$app_path" \
  --timeout 300

xcrun devicectl device copy to \
  --device "$device" \
  --source "$candidate" \
  --destination "Sift/TransformerModels/.DeviceBenchmarkCandidate" \
  --domain-type appGroupDataContainer \
  --domain-identifier group.com.alkinum.sift \
  --remove-existing-content true \
  --timeout 600

rm -rf "$result_bundle"
xcodebuild \
  -project Sift.xcodeproj \
  -scheme TransformerDeviceTests \
  -configuration Release \
  -destination "platform=iOS,id=$device" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  EXCLUDED_SOURCE_FILE_NAMES=SiftPIIDetector.mlpackage \
  "${provisioning_arguments[@]}" \
  test-without-building

rm -rf "$output/DeviceEvidence"
xcrun devicectl device copy from \
  --device "$device" \
  --source "Sift/TransformerModels/DeviceEvidence" \
  --destination "$output" \
  --domain-type appGroupDataContainer \
  --domain-identifier group.com.alkinum.sift \
  --timeout 300

runtime_report="$output/DeviceEvidence/runtime-benchmark.json"
filter_snapshot="$output/DeviceEvidence/message-filter-snapshot.json"
[[ -f "$runtime_report" ]] || { echo "error: runtime report was not exported" >&2; exit 1; }
[[ -f "$filter_snapshot" ]] || { echo "error: MessageFilter snapshot was not exported" >&2; exit 1; }

echo "runtime benchmark: $runtime_report"
echo "MessageFilter snapshot: $filter_snapshot"
echo "XCTest result: $result_bundle"
