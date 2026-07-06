#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$ROOT_DIR/apps/ios"

fail() {
  echo "error: $*" >&2
  exit 1
}

load_dotenv() {
  local env_file="$1"
  [[ -n "$env_file" ]] || return 0
  [[ -f "$env_file" ]] || fail "dotenv file not found: $env_file"
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

DOTENV_FILE="${SIFT_TESTFLIGHT_ENV_FILE:-$ROOT_DIR/.env.testflight}"
DOTENV_REQUIRED=0
FILTERED_ARGUMENTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      shift
      [[ $# -gt 0 ]] || fail "--env-file requires a value"
      DOTENV_FILE="$1"
      DOTENV_REQUIRED=1
      ;;
    --no-env-file)
      DOTENV_FILE=""
      ;;
    *)
      FILTERED_ARGUMENTS+=("$1")
      ;;
  esac
  shift
done
set -- "${FILTERED_ARGUMENTS[@]}"

if [[ -n "$DOTENV_FILE" ]]; then
  if [[ -f "$DOTENV_FILE" ]]; then
    load_dotenv "$DOTENV_FILE"
  elif [[ "$DOTENV_REQUIRED" -eq 1 || -n "${SIFT_TESTFLIGHT_ENV_FILE:-}" ]]; then
    fail "dotenv file not found: $DOTENV_FILE"
  fi
fi

PROJECT_PATH="${SIFT_IOS_PROJECT:-$IOS_DIR/Sift.xcodeproj}"
SCHEME="${SIFT_IOS_SCHEME:-SiftApp}"
CONFIGURATION="${SIFT_IOS_CONFIGURATION:-Release}"
TEAM_ID="${SIFT_DEVELOPMENT_TEAM:-PB8H83VL3Z}"
ARCHIVE_PATH="${SIFT_ARCHIVE_PATH:-$ROOT_DIR/build/ios/archives/sift-app-store.xcarchive}"
EXPORT_PATH="${SIFT_EXPORT_PATH:-$ROOT_DIR/build/ios/testflight-export}"
EXPORT_OPTIONS="${SIFT_EXPORT_OPTIONS_PLIST:-$IOS_DIR/ExportOptionsAppStore.plist}"
SET_BUILD_NUMBER="${SIFT_BUILD_NUMBER:-}"
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

  --env-file PATH
      Load a shell-compatible dotenv file before reading SIFT_* settings.
      Defaults to .env.testflight when the file exists. Use --no-env-file to
      skip dotenv loading.

  -h, --help
      Show this help.

Common xcodebuild args:
  -allowProvisioningUpdates
      Let Xcode create or download managed signing assets.

  -authenticationKeyPath PATH -authenticationKeyID KEY_ID -authenticationKeyIssuerID ISSUER_ID
      Use an App Store Connect API key for CI authentication.

Environment:
  SIFT_TESTFLIGHT_ENV_FILE  Dotenv path. Defaults to .env.testflight when present.
  SIFT_BUILD_NUMBER         Build number used as CURRENT_PROJECT_VERSION.
  SIFT_DEVELOPMENT_TEAM      Apple Developer Team ID.
  SIFT_IOS_SCHEME           Xcode scheme. Defaults to SiftApp.
  SIFT_IOS_CONFIGURATION    Xcode configuration. Defaults to Release.
  SIFT_ARCHIVE_PATH         Archive output path.
  SIFT_EXPORT_PATH          Export output path.
  SIFT_EXPORT_OPTIONS_PLIST Export options plist path.
  SIFT_APPSTORE_CONNECT_API_KEY_PATH       App Store Connect API key .p8 path.
  SIFT_APPSTORE_CONNECT_API_KEY_ID         App Store Connect API key id.
  SIFT_APPSTORE_CONNECT_API_KEY_ISSUER_ID  App Store Connect issuer id.
USAGE
}

contains_argument() {
  local needle="$1"
  shift
  local argument
  for argument in "$@"; do
    [[ "$argument" == "$needle" ]] && return 0
  done
  return 1
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

appstore_key_path="${SIFT_APPSTORE_CONNECT_API_KEY_PATH:-}"
appstore_key_id="${SIFT_APPSTORE_CONNECT_API_KEY_ID:-}"
appstore_issuer_id="${SIFT_APPSTORE_CONNECT_API_KEY_ISSUER_ID:-}"
if [[ -n "$appstore_key_path$appstore_key_id$appstore_issuer_id" ]]; then
  [[ -n "$appstore_key_path" ]] || fail "SIFT_APPSTORE_CONNECT_API_KEY_PATH is required when dotenv App Store Connect auth is used"
  [[ -n "$appstore_key_id" ]] || fail "SIFT_APPSTORE_CONNECT_API_KEY_ID is required when dotenv App Store Connect auth is used"
  [[ -n "$appstore_issuer_id" ]] || fail "SIFT_APPSTORE_CONNECT_API_KEY_ISSUER_ID is required when dotenv App Store Connect auth is used"
  [[ -f "$appstore_key_path" ]] || fail "App Store Connect API key not found: $appstore_key_path"
  if contains_argument "-authenticationKeyPath" "${XCODEBUILD_ARGUMENTS[@]}" \
    || contains_argument "-authenticationKeyID" "${XCODEBUILD_ARGUMENTS[@]}" \
    || contains_argument "-authenticationKeyIssuerID" "${XCODEBUILD_ARGUMENTS[@]}"; then
    fail "use either dotenv App Store Connect auth variables or xcodebuild authentication args, not both"
  fi
  XCODEBUILD_ARGUMENTS+=(
    "-authenticationKeyPath" "$appstore_key_path"
    "-authenticationKeyID" "$appstore_key_id"
    "-authenticationKeyIssuerID" "$appstore_issuer_id"
  )
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
