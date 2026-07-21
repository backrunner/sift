# iOS Xcode managed signing upload

This runbook covers archiving Sift from Xcode with managed automatic signing,
then uploading the archive through Organizer to App Store Connect/TestFlight.

Use this path when you want to inspect Signing & Capabilities in Xcode or make
the first account setup manually. For the terminal path, see
[iOS command-line TestFlight upload](IOS_CMD_TESTFLIGHT_UPLOAD.md).

## Release target

- Xcode project: `apps/ios/Sift.xcodeproj`
- Scheme: `SiftApp`
- App target: `SiftApp`
- Extension target: `MessageFilterExtension`
- App bundle ID: `com.alkinum.sift`
- Extension bundle ID: `com.alkinum.sift.MessageFilterExtension`
- App Group: `group.com.alkinum.sift`
- CloudKit container: `iCloud.com.alkinum.sift`
- Default Apple Developer team: `PB8H83VL3Z`

## Apple account prerequisites

Prepare these items before the first archive:

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
5. Xcode signed in to an Apple Developer account that can manage signing for
   team `PB8H83VL3Z`, or your replacement team.

Apple references:

- [Register an App ID](https://developer.apple.com/help/account/manage-identifiers/register-an-app-id/)
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)

## Open the generated project

`project.yml` is the source of truth. Regenerate the project before opening
Xcode if `project.yml` changed:

```sh
cd apps/ios
xcodegen generate
open Sift.xcodeproj
```

Do not hand-edit `Sift.xcodeproj/project.pbxproj`; update `project.yml` and run
`xcodegen generate` instead.

## Configure Xcode accounts

1. Open Xcode > Settings > Accounts.
2. Add the Apple ID that has access to the Apple Developer team.
3. Select the team and confirm Xcode can load certificates, identifiers, and
   profiles.

If Xcode prompts to create or refresh signing assets during archive or
distribution, allow it.

## Verify target signing

In Xcode, select the `Sift` project, then verify both app targets.

For `SiftApp`:

- Signing & Capabilities uses the intended team, default `PB8H83VL3Z`.
- Automatically manage signing is enabled.
- Bundle Identifier is `com.alkinum.sift`.
- App Groups contains `group.com.alkinum.sift`.
- iCloud/CloudKit uses `iCloud.com.alkinum.sift`.

For `MessageFilterExtension`:

- Signing & Capabilities uses the same team.
- Automatically manage signing is enabled.
- Bundle Identifier is `com.alkinum.sift.MessageFilterExtension`.
- App Groups contains `group.com.alkinum.sift`.
- The message-filtering entitlement is available on the extension App ID.

If Xcode cannot create a profile, fix the App ID capabilities in Apple
Developer first, then return to Xcode and refresh signing.

## Version and build number

App Store Connect requires each upload for a marketing version to use a new
integer build number.

For a committed release build, edit `apps/ios/project.yml`:

```yaml
settings:
  base:
    MARKETING_VERSION: "1.0"
    CURRENT_PROJECT_VERSION: "2"
```

Then regenerate:

```sh
cd apps/ios
xcodegen generate
```

For one-off command-line uploads, prefer the script documented in
[iOS command-line TestFlight upload](IOS_CMD_TESTFLIGHT_UPLOAD.md); its
`--build-number` flag overrides the
build number for the archive without editing project files.

## Archive and upload

1. In Xcode, select the `SiftApp` scheme.
2. Select `Any iOS Device` or `Any iOS Device (arm64)` as the destination.
3. Choose Product > Archive.
4. When Organizer opens, select the new archive.
5. Choose Distribute App.
6. Select App Store Connect.
7. Select Upload.
8. Choose automatic signing unless you intentionally prepared manual signing.
9. Keep debug symbols upload enabled.
10. Confirm CloudKit uses the Production environment for distribution.
11. Finish the upload.

If Organizer reports missing signing assets, return to Signing & Capabilities
and make sure both targets use managed signing with the same team. If the
message-filtering entitlement is missing, it must be enabled on the Apple
Developer App ID before Xcode can create a valid distribution profile.

## App Store Connect after upload

After upload, wait for App Store Connect processing to finish. Then:

1. Complete export compliance/encryption answers for the build.
2. Add the build to an internal TestFlight group for immediate team testing.
3. For external TestFlight, attach it to an external group and submit it for
   Beta App Review if required.
4. For App Store review, attach the processed build to an app version and
   complete screenshots, privacy, pricing, availability, review notes, and
   release options.

Premium Sift Signal testing through TestFlight also requires the App Store
Connect in-app purchase `com.alkinum.sift.premium`. Without it, StoreKit cannot
load a live price and the app will show the price-unavailable fallback.

## Smoke test after TestFlight processing

1. Install the processed TestFlight build on a physical iPhone.
2. Open Sift and confirm the dashboard loads.
3. Submit a local test SMS sample and verify classification appears.
4. Open the model picker and choose Sift Signal.
5. Complete Premium purchase with a sandbox/TestFlight account.
6. Choose Sift Signal again and confirm the model download starts from
   `SiftSignalModelChannelURL`.
7. Enable Sift in Settings > Messages > Unknown & Spam when the message filter
   entitlement is active, then confirm filtering behavior on device.
