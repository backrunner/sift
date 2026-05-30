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

When full Xcode is installed:

```bash
cd apps/ios
xcodegen generate
open Sift.xcodeproj
```

If Xcode commands report that the license has not been accepted, run `sudo xcodebuild -license` once from Terminal. XcodeGen is a separate project generator; install it with Homebrew if `xcodegen` is not on PATH.

The real `ILMessageFilterExtension` target requires the Apple message filtering entitlement before it can be enabled as a system filter on device. Until then, the app UI and sandbox classification path use the same `MessageFilterCore` pipeline.

The public submission endpoint defaults to `https://sift.alkinum.io/api/toc/v1/samples`.
The privacy policy URL defaults to `https://sift.alkinum.io/privacy`, and the
terms URL defaults to `https://sift.alkinum.io/tos`.

Remote sample contribution is gated by an in-app privacy notice and consent
toggle. The main dashboard also keeps the privacy policy and terms links visible
for review. The app stores the latest receipt token locally so the user can
delete the most recent remote sample after relaunching the app.
