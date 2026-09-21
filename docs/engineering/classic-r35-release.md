# Classic r35 release — 2026-09-21

`maxent-generalization-v52-full-r35` (display version `1.2`) resolves the
remaining r34 raw-label regression. The affected message described a train
delay, but the model preferred ticketing over transport operations. Production
routing was already correct; this change fixes the model's underlying label.

The candidate retains all r34 corpus rows and adds nine independent zh/en/ja
examples from `tools/apple-trainer/Training/classic-v52-rail-operations.ndjson`:
six running-status notices and three completed rebookings. Initial 27-, 18-,
and 15-row supplements corrected this boundary but lost another raw label in
acceptance v16. The nine-row candidate preserves both boundaries and was
selected only after checking all 27 established external suites.

## Artifact identity and corpus

- Model SHA-256:
  `e1ba529cb8f84ef26fe4630b5b2c9925c5f45e0ef6bbf9fd6257b17a8f2d39bf`.
- Source model: 539,242 bytes, 53 labels, multilingual Create ML MaxEnt.
- Corpus: 16,547 rows; input SHA-256
  `ffe727cdd3219717f605bd0b21557a3d01af29e8fb2a3b07a78705e6fbbc9908`.
- Internal validation fraction 0, split seed 29. Evaluation rows remain
  excluded; full training refers only to the isolated training corpus.
- Exact and digit-normalized isolation passes against all 27 suites / 1,957
  rows. Strict curation audit passes with complete zh/en/ja label coverage.

Reproduce the corpus with `prepare_classic_candidate.py`, using the r34
`selected-train.ndjson` described in [the optimization report](classic-r34-optimization.md)
as `--base`, the v52 file as `--supplement`, labels
`travel.transport,travel.ticketing`, and every path returned by
`sift_pipeline.holdout_test_sets()` as a `--holdout`. Train using MaxEnt,
multilingual language, seed 29 and validation fraction 0. Preserve the new
artifact hash and re-evaluate before publishing a reproduction.

## Actual model inference

| Metric | Published r32 | Local r33 | r34 | r35 |
| --- | ---: | ---: | ---: | ---: |
| Fixed 487 raw | 98.97% | 98.15% | 98.97% | 98.97% |
| Fixed 487 final action | 99.18% | 98.36% | 99.18% | 99.18% |
| Promotion 150 raw | 98.00% | 96.00% | 98.67% | 98.67% |
| Promotion 150 final action | 98.67% | 98.00% | 99.33% | 100% |
| Billing/card 30 raw/action | 100% | 100% | 100% | 100% |
| Conversation 30 raw/action | 100% | 100% | 100% | 100% |
| Acceptance v5 raw | 93.33% | 91.67% | 91.67% | 93.33% |
| Additional generalization 1,237 raw | 96.69% | 96.85% | 98.06% | 98.14% |
| Additional generalization 1,237 action | 99.84% | 99.27% | 100% | 100% |

Every individual suite's raw accuracy is non-regressing against **both r32
and r34**. The hash-bound core comparison also verifies final actions.
Feizhu 14 and cruise 9 retain perfect raw and action accuracy. No benign or
transactional message is routed to junk.

Across the complete external collection, raw zh/en/ja accuracy is
98.67% / 97.97% / 98.75% (679 / 639 / 639 rows). These are established
regression sets used for selection, not newly blinded production samples.

Detailed local evidence, including rejected candidates, is under
`build/classic-release-20260921/`. The `selected/` directory contains the
model, provenance, strict audit, core/travel/generalization action reports,
all-suite comparisons and language evaluation. The compact, hash-bound
[validation record](classic-r35-validation.json) is committed for review.
Model binaries remain out of Git.

## Release scope and checks

This release updates Classic and the training regression guards. PII v8 is
unchanged. Signal remains the already-published r33 / sequence 5; this Classic
work does not resolve or certify its separate IdentityLookup memory evidence
gap described in `docs/MESSAGE_FILTER_MEMORY.md`.

Swift build, 250 iOS-module tests, CoreSmokeTests, three Apple trainer tests,
eleven pipeline tests, all 143 transformer tooling tests, TypeScript typecheck
and 30 TypeScript tests pass. The built-in model packaging workflow compiles
and hashes Classic and PII before publication. A local unsigned Release
archive also passed the post-archive model resource checks: Classic appears
in the App and extension, PII only in the App, and no Premium artifact is
bundled. `BuiltinModels.lock.json` is the authoritative immutable archive URL
and checksum for Xcode Cloud.

The built-in ZIP was uploaded to the immutable r35+PII-v8 R2 key and fully
downloaded through the public model route. Its verified SHA-256 is
`5b6584d32637049db853df42b9b0e54bd915a7c7266109b32e269da827be9a2d`.
Both archived Classic manifests match the new lock. Xcode Cloud consumes
this package when the verified main commit is merged and pushed to release.
