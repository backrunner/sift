# Model download sheet and live verification — 2026-09-21

The model picker opens as a 520-point bottom sheet, scaled for Dynamic Type,
with the dashboard still visible behind it. Users can expand it. Picker and
detail views share transfer progress, downloaded/total bytes, installation
status, cancellation and retry controls. Metadata stays visible during an
update. Common connection failures have localized, actionable messages.

## Production download and engine evidence

`TransformerLiveDownloadTests` is an explicitly opted-in iOS integration test,
outside the offline SwiftPM unit suite. It uses the app's configured production
downloader through `SiftAppModel.selectModelVariant`, including signed catalog
selection, artifact checksums, background URLSession downloads, Core ML
compilation, App Group installation and switching to the loaded classifier.
Only StoreKit entitlement and CloudKit sample submission are replaced in this
test; it never purchases a product or submits samples.

The signed iPhone 17 simulator run passed with:

- Release: `signal-v4-generalization-v50-r33-distilled-12l`, sequence 5.
- Model SHA-256: `f78af4d0f4cbfb15308b43bccf395aebde42a6f0fbfad0c197c36792210b904f`.
- Download: 108,748,513 bytes, with 176 distinct observed progress values.
- States: checking, downloading, installing, ready.
- Download through loaded-model selection: 24.88 seconds in this run.
- A separate `MessageFilterEngine` cold-loaded the installed model and then
  retained it for subsequent queries. Synthetic Chinese order, English scam,
  and Japanese promotion cases all used the `signal` execution path, with
  `model` decisions, the expected actions and no fallback.

The test verifies the App Group entitlement before downloading. An unsigned
simulator host cannot demonstrate the shared installation path: the production
loader intentionally refuses an iOS per-process storage fallback. The initial
unsigned attempt exposed that test-host setup issue; the passing run used ad-hoc
simulator signing and the actual App Group container.

The local evidence JSON is retained under
`build/download-ui-20260921/production-download-and-engine-evidence.json`
(ignored), and as a permanent XCTest attachment in the result bundle.

Reproduce using an isolated simulator with an unmetered connection:

```bash
cd apps/ios
xcodegen generate
xcodebuild -project Sift.xcodeproj -scheme TransformerDeviceTests \
  -configuration Release \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath /tmp/sift-live-download-build \
  -resultBundlePath /tmp/sift-live-download.xcresult \
  -only-testing:TransformerDeviceTests/TransformerLiveDownloadTests \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  SIFT_LIVE_MODEL_DOWNLOAD=1 CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

The integration run uses a UUID-named, cleaned preferences suite. It leaves the
downloaded model in the test host's App Group for inspection. Without the opt-in
flag, the integration test skips before accessing the network.

## Release validation

Swift build, all 253 SwiftPM tests and CoreSmokeTests pass. The live integration
test passes separately. An unsigned generic-iOS Release archive passes the
repository's post-archive checks: pinned Classic in both app and extension,
PII only in the app, and no bundled Premium model. Built-in model hashes and
compilation were also verified against `BuiltinModels.lock.json`.

Simulator layout checks cover the floating sheet with visible background,
transfer and failure states, English/Japanese copy, large accessibility text,
and dark appearance. These visual fixtures are removed from the source; the
download and engine evidence above comes from the real production transfer.

## Evidence boundary

The simulator support override is confined to this test. The production
hardware gate is unchanged. These results prove real download, installation,
loading and host-side filter-engine execution; they do not prove execution
inside IdentityLookup's process or its memory budget.

Physical-iPhone incoming-SMS verification was explicitly skipped for this
change. The previously observed extension Jetsam issue and its remaining
verification requirement in `../MESSAGE_FILTER_MEMORY.md` remain unresolved.
No replacement model, release signature, compatibility boundary or taxonomy
was changed.
