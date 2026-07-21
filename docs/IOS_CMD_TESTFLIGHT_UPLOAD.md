# iOS command-line TestFlight upload

This runbook covers the fully scripted path for archiving Sift, letting Xcode
managed signing create or download signing assets, and uploading the archive to
App Store Connect/TestFlight.

Use this path when you want a reproducible terminal command for a local Mac or
CI runner. For the Xcode Organizer path, see
[iOS Xcode managed signing upload](IOS_XCODE_MANAGED_SIGNING.md).

## Release target

- Xcode project: `apps/ios/Sift.xcodeproj`
- Scheme: `SiftApp`
- Configuration: `Release`
- App bundle ID: `com.alkinum.sift`
- Extension bundle ID: `com.alkinum.sift.MessageFilterExtension`
- App Group: `group.com.alkinum.sift`
- CloudKit container: `iCloud.com.alkinum.sift`
- Default Apple Developer team: `PB8H83VL3Z`
- Export options: `apps/ios/ExportOptionsAppStore.plist`
- Upload script: `tools/upload_ios_testflight.sh`
- Package script: `pnpm upload:ios-testflight`

## Apple account prerequisites

Prepare these items before the first upload:

1. Apple Developer explicit App IDs for:
   - `com.alkinum.sift`
   - `com.alkinum.sift.MessageFilterExtension`
2. Capabilities on the App IDs:
   - App Groups with `group.com.alkinum.sift`
   - iCloud with CloudKit container `iCloud.com.alkinum.sift`
   - Message-filtering entitlement for the extension App ID
3. App Store Connect app record for bundle ID `com.alkinum.sift`.
4. App Store Connect in-app purchase if Premium is tested through TestFlight:
   - Type: non-consumable
   - Product ID: `com.alkinum.sift.premium`
5. A signed-in Apple Developer account in Xcode, or an App Store Connect API
   key for CI.

Apple references:

- [Register an App ID](https://developer.apple.com/help/account/manage-identifiers/register-an-app-id/)
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [App Store Connect API](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)

## Local prerequisites

Install and select the intended Xcode:

```sh
xcode-select -p
xcodebuild -version
```

Accept the license if needed:

```sh
sudo xcodebuild -license
```

Install project dependencies and regenerate the project after `project.yml`
changes:

```sh
pnpm install
cd apps/ios
xcodegen generate
cd ../..
```

Run the minimum iOS checks before archiving:

```sh
cd apps/ios
swift build
swift test
swift run CoreSmokeTests
cd ../..
```

## Upload with managed signing

From the repository root, pass a monotonically increasing App Store Connect
build number:

```sh
pnpm upload:ios-testflight --build-number 2 -allowProvisioningUpdates
```

`-allowProvisioningUpdates` lets `xcodebuild` communicate with Apple Developer.
For automatically signed targets, Xcode can create or update App IDs,
certificates, and provisioning profiles. This requires either a signed-in Xcode
account or App Store Connect API key flags.

The script does not edit `project.yml`; `--build-number` overrides
`CURRENT_PROJECT_VERSION` for that archive. Use a new integer for every upload
of the same marketing version.

Override the Apple Developer team when needed:

```sh
pnpm upload:ios-testflight \
  --build-number 2 \
  --team-id YOUR_TEAM_ID \
  -allowProvisioningUpdates
```

## CI authentication

For CI or a clean Mac where Xcode is not signed in interactively, pass the App
Store Connect API key flags through to `xcodebuild`:

```sh
pnpm upload:ios-testflight \
  --build-number 2 \
  -allowProvisioningUpdates \
  -authenticationKeyPath /secure/path/AuthKey_KEY_ID.p8 \
  -authenticationKeyID KEY_ID \
  -authenticationKeyIssuerID ISSUER_ID
```

Do not commit `.p8` keys, exported certificates, provisioning profiles, or Apple
account credentials.

## What the script does

`tools/upload_ios_testflight.sh`:

1. Validates that `apps/ios/Sift.xcodeproj` and
   `apps/ios/ExportOptionsAppStore.plist` exist.
2. Copies the export options plist to a temporary file and sets `teamID`.
3. Archives with:

   ```sh
   xcodebuild archive \
     -project apps/ios/Sift.xcodeproj \
     -scheme SiftApp \
     -configuration Release \
     -destination "generic/platform=iOS" \
     -archivePath build/ios/archives/sift-app-store.xcarchive \
     CODE_SIGN_STYLE=Automatic \
     DEVELOPMENT_TEAM=PB8H83VL3Z \
     CURRENT_PROJECT_VERSION=<build-number>
   ```

4. Fails before export unless both the app and message-filter extension declare
   `UIDeviceFamily = [1]`. Sift is distributed as an iPhone-only app, so App
   Store Connect must not require native iPad screenshots.
5. Fails before export if the app archive contains any `SiftSignalModel*` or
   legacy `SiftTransformerClassifier*` artifact. Premium model files must be
   downloaded on demand after entitlement unlock and user selection.
6. Exports and uploads with:

   ```sh
   xcodebuild -exportArchive \
     -archivePath build/ios/archives/sift-app-store.xcarchive \
     -exportPath build/ios/testflight-export \
     -exportOptionsPlist <temporary-export-options.plist>
   ```

The export options use:

- `destination=upload`
- `method=app-store-connect`
- `signingStyle=automatic`
- `signingCertificate=Apple Distribution`
- `uploadSymbols=true`

`xcodebuild -help` documents these flags and export option keys on the local
Xcode installation.

## App Store Connect after upload

After upload, wait for App Store Connect processing to finish. Then:

1. Answer export compliance/encryption questions for the processed build.
2. Add the build to an internal TestFlight group.
3. For external TestFlight, add it to an external group and submit it for Beta
   App Review if App Store Connect requires review.
4. For App Store release, create or open the iOS app version, attach the build,
   finish screenshots, privacy, pricing, availability, review notes, and submit
   the version for review.

## Common failures

- `No Accounts`: sign in under Xcode > Settings > Accounts, or pass App Store
  Connect API key flags.
- Provisioning errors for app groups, iCloud, or the extension: confirm both App
  IDs have the exact capabilities and identifiers listed above.
- Message-filtering entitlement errors: request/enable the entitlement on the
  extension App ID before uploading.
- `Missing App Store Connect app record`: create the app record for
  `com.alkinum.sift`.
- Build number already used: pass a larger `--build-number`.
- Premium purchase cannot load price in TestFlight: create and attach the
  non-consumable `com.alkinum.sift.premium` in App Store Connect.
