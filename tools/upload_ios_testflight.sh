#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$ROOT_DIR/apps/ios"
PROJECT_PATH="${SIFT_IOS_PROJECT:-$IOS_DIR/Sift.xcodeproj}"
SCHEME="${SIFT_IOS_SCHEME:-SiftApp}"
CONFIGURATION="${SIFT_IOS_CONFIGURATION:-Release}"
TEAM_ID="${SIFT_DEVELOPMENT_TEAM:-PB8H83VL3Z}"
ARCHIVE_PATH="${SIFT_ARCHIVE_PATH:-$ROOT_DIR/build/ios/archives/sift-app-store.xcarchive}"
EXPORT_PATH="${SIFT_EXPORT_PATH:-$ROOT_DIR/build/ios/testflight-export}"
EXPORT_OPTIONS="${SIFT_EXPORT_OPTIONS_PLIST:-$IOS_DIR/ExportOptionsAppStore.plist}"
SET_BUILD_NUMBER=""
XCODEBUILD_ARGUMENTS=()

usage() {
  cat <<'USAGE'
Usage: tools/upload_ios_testflight.sh [options] [xcodebuild args...]

Archives Sift for iOS and uploads the exported archive to App Store Connect.
The default path uses Xcode-managed automatic signing.

Options:
  --build-number BUILD_NUMBER
      Use BUILD_NUMBER as CURRENT_PROJECT_VERSION for this archive.

  --team-id TEAM_ID
      Override the Apple Developer Team ID. Defaults to SIFT_DEVELOPMENT_TEAM
      or PB8H83VL3Z.

  --archive-path PATH
      Override the .xcarchive output path.

  --export-path PATH
      Override the export/upload output path.

  --export-options-plist PATH
      Override the App Store Connect export options plist.

  -h, --help
      Show this help.

Common xcodebuild args:
  -allowProvisioningUpdates
      Let Xcode create or download managed signing assets.

  -authenticationKeyPath PATH -authenticationKeyID KEY_ID -authenticationKeyIssuerID ISSUER_ID
      Use an App Store Connect API key for CI authentication.

Environment:
  SIFT_DEVELOPMENT_TEAM      Apple Developer Team ID.
  SIFT_IOS_SCHEME           Xcode scheme. Defaults to SiftApp.
  SIFT_IOS_CONFIGURATION    Xcode configuration. Defaults to Release.
  SIFT_ARCHIVE_PATH         Archive output path.
  SIFT_EXPORT_PATH          Export output path.
  SIFT_EXPORT_OPTIONS_PLIST Export options plist path.
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-number)
      shift
      [[ $# -gt 0 ]] || fail "--build-number requires a value"
      SET_BUILD_NUMBER="$1"
      ;;
    --team-id)
      shift
      [[ $# -gt 0 ]] || fail "--team-id requires a value"
      TEAM_ID="$1"
      ;;
    --archive-path)
      shift
      [[ $# -gt 0 ]] || fail "--archive-path requires a value"
      ARCHIVE_PATH="$1"
      ;;
    --export-path)
      shift
      [[ $# -gt 0 ]] || fail "--export-path requires a value"
      EXPORT_PATH="$1"
      ;;
    --export-options-plist)
      shift
      [[ $# -gt 0 ]] || fail "--export-options-plist requires a value"
      EXPORT_OPTIONS="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      XCODEBUILD_ARGUMENTS+=("$1")
      ;;
  esac
  shift
done

[[ -d "$PROJECT_PATH" ]] || fail "Xcode project not found at $PROJECT_PATH"
[[ -f "$EXPORT_OPTIONS" ]] || fail "export options plist not found at $EXPORT_OPTIONS"
[[ -n "$TEAM_ID" ]] || fail "team id is empty; set SIFT_DEVELOPMENT_TEAM or pass --team-id"

if [[ -n "$SET_BUILD_NUMBER" && ! "$SET_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  fail "--build-number must be a non-negative integer"
fi

mkdir -p "$ROOT_DIR/build/ios" "$(dirname "$ARCHIVE_PATH")" "$EXPORT_PATH"

runtime_export_options="$(mktemp "$ROOT_DIR/build/ios/export-options.XXXXXX")"
trap 'rm -f "$runtime_export_options"' EXIT
cp "$EXPORT_OPTIONS" "$runtime_export_options"
if ! /usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" "$runtime_export_options" 2>/dev/null; then
  /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$runtime_export_options"
fi

archive_build_settings=(
  "CODE_SIGN_STYLE=Automatic"
  "DEVELOPMENT_TEAM=$TEAM_ID"
)

if [[ -n "$SET_BUILD_NUMBER" ]]; then
  archive_build_settings+=("CURRENT_PROJECT_VERSION=$SET_BUILD_NUMBER")
fi

cd "$ROOT_DIR"

xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  "${archive_build_settings[@]}" \
  "${XCODEBUILD_ARGUMENTS[@]}"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$runtime_export_options" \
  "${XCODEBUILD_ARGUMENTS[@]}"

echo "Uploaded Sift iOS archive to App Store Connect."
