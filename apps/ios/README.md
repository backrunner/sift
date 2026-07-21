# Sift iOS

This folder is intentionally split in two:

- `Package.swift` builds the shared Swift modules and tests without a full Xcode project.
- `project.yml` describes the iOS app and message filter extension for XcodeGen.

Local package checks:

```bash
swift test
swift run CoreSmokeTests
swift run ClassicMessageFilterArtifactTests \
  --model GeneratedModels/SiftSMSClassifier.mlmodel \
  --fixed ../../tools/apple-trainer/Evaluation/classification-regressions.ndjson \
  --promotion ../../tools/apple-trainer/Evaluation/promotion-regressions.ndjson \
  --conversation ../../tools/transformer-trainer/Evaluation/conversation-regressions.ndjson \
  --output ../../build/pipeline/apple-model/classic-message-filter-report.json
```

Train or refresh the bundled base model from the shared generic `text`/`label`
NDJSON corpus:

```bash
cd ../..
pnpm pipeline -- fetch-public
pnpm pipeline -- curate --strict-audit
pnpm pipeline -- augment
pnpm pipeline -- train-classic --algorithm-classic maxent --install-ios
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

The Premium Transformer requires an A12-class Neural Engine or newer
(`iPhone11,*` / `iPad8,*` minimum). Older iPhones and iPads, iPods, simulators,
and unknown hardware identifiers stay on Classic. The app disables the Premium
settings row, blocks purchase/download/model switching with localized feedback,
and the message-filter engine independently refuses to load the Transformer so
a restored App Group selection cannot bypass the device gate.

For local Simulator or device testing, set the Debug scheme environment
variable `SIFT_DEBUG_PREMIUM_UNLOCKED=1`. This selects an unlocked in-process
Premium backend only in `DEBUG`; Release builds always use StoreKit.

Release builds must inject the raw Ed25519 public key used to verify the signed
model channel and immutable release manifest:

```bash
xcodebuild ... \
  SIFT_TRANSFORMER_MODEL_PUBLIC_KEY_ID=release-2026 \
  SIFT_TRANSFORMER_MODEL_PUBLIC_KEY='<raw-public-key-base64>'
```

The private key remains only on the publisher. An empty public-key build keeps
the installed model but disables update discovery and download.

The message-filter extension reads one atomic shared configuration snapshot on
every query. It refreshes the Transformer runtime when the artifact identity
changes, while rules and category mappings take effect immediately even if iOS
keeps the extension process alive. On device this requires the
`group.com.alkinum.sift` App Group to be provisioned for both targets.

## Sanitization (two tracks)

`PrivacySanitizer` always runs its deterministic rules (phone, URL, email,
identity documents `{{ID}}`, vehicle plates `{{PLATE}}`, bank card,
order/pickup/verification codes, amounts, addresses, names). If the optional
`SiftPIIDetector.*` artifacts from
`tools/pii-trainer` are bundled, a Core ML token-classification model runs on
top and its detections are **unioned** with the rules — the model can only
widen recall, never lose a rule hit. Anonymous submissions also carry the
local model's own coarse classification (`predictedLabel`,
`predictedConfidence`, `agreement`) so the training pipeline can weigh
disagreements; a high-confidence mismatch shows a non-blocking hint after
submitting.

The PII model artifacts are not part of the default TestFlight build. Keep the
app rules-only unless the trainer produces an accepted model, then wire the
generated `SiftPIIDetector.*` files into `project.yml` for that release.

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

Detailed release runbooks live in:

- [iOS command-line TestFlight upload](../../docs/IOS_CMD_TESTFLIGHT_UPLOAD.md)
  for terminal uploads with
  `tools/upload_ios_testflight.sh`
- [iOS Xcode managed signing upload](../../docs/IOS_XCODE_MANAGED_SIGNING.md)
  for Xcode Managed Signing and Organizer uploads

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
The privacy policy URL defaults to the GitHub-hosted
`docs/legal/PRIVACY_POLICY.md`, and the terms URL defaults to
`docs/legal/TERMS_OF_SERVICE.md`.

Remote sample contribution is gated by an in-app privacy notice and consent
toggle. The main dashboard also keeps the privacy policy and terms links visible
for review. The app stores the latest receipt (the CloudKit record name)
locally so the user can delete the most recent remote sample after relaunching
the app.
