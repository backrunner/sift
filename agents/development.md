# Development Workflow And Rules

## Environment

Use macOS with Xcode 16 (Swift 6), pnpm 10, uv (Python 3.10-3.12), and
XcodeGen. After `pnpm install`, TypeScript tooling is ready. For iOS, run
`cd apps/ios && swift build`.

## Validation Matrix

Run the relevant checks before committing:

| Change | Required validation |
| --- | --- |
| Swift app or core code | `swift build && swift test && swift run CoreSmokeTests` from `apps/ios` |
| `project.yml` or resources | `xcodegen generate`, then build |
| `taxonomy.json` | `pnpm --filter @sift/taxonomy generate:swift` plus iOS build and trainer synthetic-data smoke test |
| Corpus templates | Trainer smoke test plus `curate --audit-only --strict-audit` |
| Curation or training scripts | `python3 -m py_compile` plus `python3 -m unittest discover -s tools/transformer-trainer/tests` |
| TypeScript tooling | `pnpm typecheck && pnpm test` |
| Legal or privacy behavior | Update `docs/PRIVACY.md` and `docs/legal/*` together |

## Testing Rules

- **Zero false-positive tolerance:** assert concrete values, not "does not
  crash." Polling waits must have timeouts and record failures with
  `Issue.record`.
- Shared state (`UserDefaults`, App Group stores, ledgers) must use injected,
  isolated suites and be safe for parallel tests.
- External services (CloudKit, StoreKit, network) are tested through protocol
  mocks. Real backend validation belongs on device.
- Keep UI thin. Put business assertions in `SiftAppModel` or core tests.

## Localization Workflow

1. Add new UI copy with `String(localized:)`; zh-Hans is the source language.
2. Add matching en/ja entries in `apps/ios/SiftApp/Localizable.xcstrings`.
   Interpolated keys use `%@`, `%lld`, and similar placeholders.
3. Category names come from `taxonomy.json` `titles`; do not hard-code them.

## Data And Privacy Change Checklist

Any new cloud field requires all of the following: `schema.ckdb`, client writes,
the `export --raw` path, `infra/cloudkit/README.md`, `docs/PRIVACY.md`, and
legal copy. Schema changes require `xcrun cktool save-schema` import for dev
and then production.

## Release Artifacts

- App: `tools/upload_ios_testflight.sh` for TestFlight uploads.
- Models: `pnpm pipeline -- all --install-ios` produces and installs local
  artifacts. Transformer and PII artifacts are optional; when absent, the app
  falls back to the classic model or pure-rule redaction.
- IAP: configure the non-consumable `com.alkinum.sift.premium` in App Store
  Connect.
