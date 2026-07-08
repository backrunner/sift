# AGENTS.md - Sift Development Guide

> A compact project map and hard rules for AI coding agents and new contributors.
> See the detailed guides in `agents/`:
> [architecture.md](agents/architecture.md) and [development.md](agents/development.md).

## What This Project Is

Sift is a privacy-first iOS SMS filtering app. Classification runs on device
through an IdentityLookup extension, using a 50-leaf taxonomy with first-class
zh/en/ja coverage, a dual-model setup (a locally fine-tunable Create ML classic
model plus a paid Premium transformer model), anonymous CloudKit sample
collection, user-private statistics, and an automated training pipeline.
The product is not launched yet; backward compatibility is not required.

## Directory Map

| Path | Contents |
| --- | --- |
| `apps/ios` | SwiftPM modules (`MessageFilterCore`, `SiftAppKit`, `MessageFilterExtensionKit`) plus the XcodeGen project |
| `apps/site` | SvelteKit/svedocs public website for `sift.alkinum.io`; do not use the default svedocs pixel theme |
| `packages/taxonomy` | Taxonomy source of truth (`taxonomy.json`); `generate:swift` emits `Taxonomy.swift` |
| `tools/apple-trainer` | Create ML trainer plus multilingual synthetic corpora |
| `tools/transformer-trainer` | mmBERT/Core ML trainer and `curate_dataset.py` quality audit tooling |
| `tools/pii-trainer` | Optional Core ML PII redaction model trainer |
| `tools/cloudkit` | CloudKit server-side export tooling in TypeScript |
| `tools/pipeline` | `pnpm pipeline` orchestration in Python stdlib |
| `infra/cloudkit` | CloudKit container schema (`schema.ckdb`) for `cktool` import |
| `docs/` | Taxonomy, training, privacy, and store-grade legal documents |

## Hard Rules

1. **Never change taxonomy ids.** Display names come from `taxonomy.json`
   `titles` (zh/en/ja). After taxonomy edits, run
   `pnpm --filter @sift/taxonomy generate:swift`.
2. **zh/en/ja are first-class languages.** New leaves must have complete
   trilingual seed templates. Corpus changes must pass `curate --strict-audit`.
3. **User-facing copy must be localized.** Use `String(localized:)` in Swift
   and keep `apps/ios/SiftApp/Localizable.xcstrings` synchronized with
   zh-Hans as the source language and en/ja filled in. Do not localize regexes,
   identifiers, or storage keys.
4. **Privacy boundary:** sample payloads must never carry identity fields;
   statistics are counts only. Any new cloud field must be reflected in
   `schema.ckdb`, the `--raw` export path, `docs/PRIVACY.md`, and legal copy.
5. **Test isolation:** tests touching shared `UserDefaults` or App Group state
   must use a UUID-suffixed suite and clean it with `removePersistentDomain`.
   Tests must not depend on execution order.
6. **Inject side effects.** CloudKit and StoreKit access must go through
   protocol seams (`RemoteSampleSubmitting`, `PremiumPurchasing`). Unit tests
   must not touch the network. `CKContainer` construction must be guarded with
   `#if os(iOS)` or injected because entitlement-free environments can throw
   Objective-C exceptions.
7. **XcodeGen is the project source of truth.** After editing `project.yml`,
   run `xcodegen generate`; do not hand-edit `project.pbxproj`.
8. **Model artifacts do not go in git.** Transformer and PII artifacts under
   `GeneratedModels/` are installed by trainers via `--install-ios` and marked
   optional in `project.yml`.
9. Swift 6 strict concurrency applies: types crossing actor boundaries must be
   explicitly `Sendable`.
10. Minimum pre-commit validation:
    `cd apps/ios && swift build && swift test && swift run CoreSmokeTests`
    plus `pnpm typecheck && pnpm test` for TypeScript changes, and
    `python3 -m unittest discover -s tools/transformer-trainer/tests` for
    corpus or curation changes.

## Common Commands

```bash
pnpm pipeline -- all --install-ios      # Full automated training pipeline
pnpm pipeline -- finetune               # Incremental fine-tuning from checkpoint
pnpm export:training                    # Export CloudKit samples
pnpm -C apps/site dev                   # Run the public website locally
pnpm -C apps/site build                 # Build the public website
cd apps/ios && xcodegen generate        # Regenerate the Xcode project
```
