# Sift iOS

This folder is intentionally split in two:

- `Package.swift` builds the shared Swift modules and tests without a full Xcode project.
- `project.yml` describes the iOS app and message filter extension for XcodeGen.

Local package checks:

```bash
swift test
swift run CoreSmokeTests
```

Train or refresh the bundled base model from the shared generic `text`/`label`
NDJSON corpus:

```bash
cd ../../tools/apple-trainer
swift run SiftAppleTrainer --build-public-corpus ../../build/public-corpus.ndjson --per-label 80 --public-per-label 500
swift run SiftAppleTrainer --input ../../build/public-corpus.ndjson --out ../../build/apple-model --algorithm auto --install-ios
```

## Model variants

The app ships two classifier variants, switchable from the model capsule on
the dashboard (the selection is shared with the message-filter extension via
the `group.com.alkinum.sift` app group):

- **Classic model** — the Create ML text classifier above plus the on-device
  personalization adapter. Supports local fine-tuning from the local-only
  sample queue.
- **Transformer** — a frozen multilingual mmBERT model exported by
  `tools/transformer-trainer` and uploaded to the public model CDN. It is
  downloaded into the shared App Group only after a Premium user explicitly
  switches to the Transformer variant. It is **not** fine-tunable on device;
  while selected, the app hides local fine-tuning UI and only offers anonymous
  CloudKit contribution.

The message-filter extension re-reads the shared selection (and custom rules)
on every query, so switching models in the app takes effect in the system
filter immediately — including when iOS keeps the extension process alive
across queries. On device this requires the `group.com.alkinum.sift` App
Group to be provisioned for both targets.

## Sanitization (two tracks)

`PrivacySanitizer` always runs its deterministic rules (phone, URL, email,
identity documents `{{ID}}`, bank card, order/pickup/verification codes, amounts,
addresses, names). If the optional `SiftPIIDetector.*` artifacts from
`tools/pii-trainer` are bundled, a Core ML token-classification model runs on
top and its detections are **unioned** with the rules — the model can only
widen recall, never lose a rule hit. Anonymous submissions also carry the
local model's own coarse classification (`predictedLabel`,
`predictedConfidence`, `agreement`) so the training pipeline can weigh
disagreements; a high-confidence mismatch shows a non-blocking hint after
submitting.

When full Xcode is installed:

```bash
cd apps/ios
xcodegen generate
open Sift.xcodeproj
```

If Xcode commands report that the license has not been accepted, run `sudo xcodebuild -license` once from Terminal. XcodeGen is a separate project generator; install it with Homebrew if `xcodegen` is not on PATH.

## TestFlight upload

The Xcode project is configured for Xcode-managed automatic signing on the
`SiftApp` app target and the `MessageFilterExtension` target. The default team
matches the existing Alkinum App Store Connect setup used by sibling projects:
`PB8H83VL3Z`. Override it with `SIFT_DEVELOPMENT_TEAM` or `--team-id` if needed.

After the App IDs and message-filtering entitlement are ready in Apple
Developer, upload a TestFlight build from the repository root with:

```bash
pnpm upload:ios-testflight --build-number 2 -allowProvisioningUpdates
```

`-allowProvisioningUpdates` lets Xcode create or download managed certificates
and provisioning profiles for App Store Connect. For CI, pass the usual
`xcodebuild` App Store Connect API-key flags through the script:

```bash
pnpm upload:ios-testflight \
  --build-number 2 \
  -allowProvisioningUpdates \
  -authenticationKeyPath /path/to/AuthKey.p8 \
  -authenticationKeyID KEY_ID \
  -authenticationKeyIssuerID ISSUER_ID
```

The script archives the `SiftApp` scheme, exports with
`apps/ios/ExportOptionsAppStore.plist`, and uploads to App Store Connect. The
default archive path is `build/ios/archives/sift-app-store.xcarchive`; the
default export path is `build/ios/testflight-export`.

The real `ILMessageFilterExtension` target requires the Apple message filtering entitlement before it can be enabled as a system filter on device. Until then, the app UI and sandbox classification path use the same `MessageFilterCore` pipeline.

Once the Apple Developer account has access, enable the managed SMS/Call Reporting message-filtering capability for the explicit App IDs:

- `com.alkinum.sift`
- `com.alkinum.sift.MessageFilterExtension`

Then regenerate/download the development and App Store provisioning profiles for both identifiers, open `Sift.xcodeproj`, select the team in Signing & Capabilities for both `SiftApp` and `MessageFilterExtension`, and let Xcode refresh automatic signing. The app target entitlements declare the `iCloud.com.alkinum.sift` CloudKit container plus the `group.com.alkinum.sift` app group, and the extension declares the same app group — enable those capabilities for the App IDs alongside the message-filtering entitlement. If the filter later defers classification to a server with `deferQueryRequestToNetwork`, also add Associated Domains with `messagefilter:<domain>` and set `ILMessageFilterExtensionNetworkURL` in `MessageFilterExtension/Info.plist`.

Anonymous sample contribution writes `SmsSample` records into the CloudKit
public database of `iCloud.com.alkinum.sift` (configurable through the
`SiftCloudKitContainerIdentifier` Info.plist key; the schema lives in
`infra/cloudkit/schema.ckdb`). Contribution requires an iCloud session on the
device.
The privacy policy URL defaults to `https://sift.alkinum.io/privacy`, and the
terms URL defaults to `https://sift.alkinum.io/tos`.

Remote sample contribution is gated by an in-app privacy notice and consent
toggle. The main dashboard also keeps the privacy policy and terms links visible
for review. The app stores the latest receipt (the CloudKit record name)
locally so the user can delete the most recent remote sample after relaunching
the app.
