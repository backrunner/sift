# AGENTS.md - Sift Development Guide

> A compact project map and hard rules for AI coding agents and new contributors.
> See the detailed guides in `agents/`:
> [architecture.md](agents/architecture.md) and [development.md](agents/development.md).

## What This Project Is

Sift is a privacy-first iOS SMS filtering app. Classification runs on device
through an IdentityLookup extension, using a 51-leaf taxonomy with first-class
zh/en/ja coverage, a dual-model setup (a locally fine-tunable Create ML classic
model plus a paid Premium transformer model), anonymous CloudKit sample
collection, user-defined allow/block rules, and an automated training pipeline.
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
4. **Privacy boundary:** sample payloads must never carry identity fields. Any
   new cloud field must be reflected in `schema.ckdb`, the `--raw` export path,
   `docs/PRIVACY.md`, and legal copy.
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
8. **Model artifacts do not go in git.** Trainers may install Transformer and
   PII artifacts under `GeneratedModels/` for local validation. Production
   targets must bundle the classic and PII models only; the Premium Transformer
   must not appear in `project.yml` resources or an archive because it downloads
   on demand after entitlement unlock and explicit user selection.
9. Swift 6 strict concurrency applies: types crossing actor boundaries must be
   explicitly `Sendable`.
10. Minimum pre-commit validation:
    `cd apps/ios && swift build && swift test && swift run CoreSmokeTests`
    plus `pnpm typecheck && pnpm test` for TypeScript changes, and
    `python3 -m unittest discover -s tools/transformer-trainer/tests` for
    corpus or curation changes.
11. **Model selection must use leak-free external holdouts.** Before comparing
    candidates, remove exact and digit-normalized near duplicates against both
    `tools/apple-trainer/Evaluation/classification-regressions.ndjson` and
    `tools/apple-trainer/Evaluation/promotion-regressions.ndjson`, plus the
    billing/card boundary set when those labels are touched. Never select
    a model from its internal validation score alone.
12. **PII models have a false-positive gate.** `--install-ios` must keep PII
    micro F1 >= 0.90 and clean-sentence FPR <= 0.02 on both the synthetic eval
    and `tools/pii-trainer/Evaluation/clean-negatives.ndjson`.
13. **Branch policy:** all development commits land on `main` first. The
    `release` branch is only updated by merging the verified `main` tip for an
    Xcode Cloud release build, then pushing that merge. Do not commit directly
    to `release`; Xcode Cloud workflows bind to `release`, while local builds
    use `main`.

## Current Model Baselines (2026-07-24)

| Variant | Version | Fixed 474 | Promotion 150 | Notes |
| --- | --- | ---: | ---: | --- |
| Classic | `maxent-boundary-v19` | 98.73% | 96.00% | Billing/card 90.00% raw / 100% action; Conversation 30/30 abstain; 354.0 KB |
| Premium | `signal-v2-boundary-v15` | 99.37% | 99.33% | Billing/card 93.33%; 22-layer W8A16 Core ML, CPU-only; build >= 10; 159,107,726 download bytes |
| PII | `pii-boundary-v7` | n/a | n/a | Core ML INT8 P 99.27%, R 98.90%, F1 99.08%; clean FPR 0/487 and 0/64; grouped amounts |

The current Signal release was trained on 14,390 leak-free rows with complete
zh/en/ja coverage. The pipeline isolates all 684 fixed, promotion, billing/card,
and conversation holdout rows by exact and digit-normalized signatures before
either model trains.
The 150-row promotion boundary set spans game marketplaces, retail, finance,
carrier offers, travel, insurance, services, loans, and housing, with paired
order, points, bank, data-usage, update, and scam negatives. The previous
`maxent-boundary-v2` scored only 45.65% on the expanded promotion set, so do
not restore it based on fixed-set accuracy alone.

## Common Commands

```bash
pnpm pipeline -- all --install-ios      # Full automated training pipeline
pnpm pipeline -- finetune               # Incremental fine-tuning from checkpoint
pnpm export:training                    # Export CloudKit samples
python3 tools/apple-trainer/Scripts/prepare_classic_candidate.py --help
                                            # Build a holdout-isolated corpus
pnpm -C apps/site dev                   # Run the public website locally
pnpm -C apps/site build                 # Build the public website
cd apps/ios && xcodegen generate        # Regenerate the Xcode project
```
