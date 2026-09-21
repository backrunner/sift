# Classic r34 optimization — 2026-09-20

Historical local candidate `maxent-generalization-v51-full-r34` replaced the
unqualified r33 in `GeneratedModels`. It was never published. The subsequent
[r35 release](classic-r35-release.md) resolves its remaining raw-label
regression; the results below document the r34 experiment.

## Why r33 regressed

r32 used 16,472 corpus rows; r33 used 19,254. Comparing `(text, label)` pairs
found 10,993 shared rows, 5,479 removed rows and 8,261 additions. This was a
substantial corpus replacement, not a small incremental expansion. Removed
rows concentrated in carrier usage/offers, banking, messages, orders and
points. Additional generic templates and public-source text changed MaxEnt's
feature statistics. More rows did not preserve the earlier decision boundaries.

The historical manifests did not record input hashes or actual split seeds.
The name `seed29` is not proof of the invocation's seed; the pipeline default
was 42. A controlled r33-corpus run with seed 29 still scored only 98.36%
fixed and 96.67% promotion. Using the complete r33 training corpus, without
an internal split, produced the same raw scores. Restoring the r32 corpus
and training on all isolated rows reached 98.97% / 98.67%. These ablations
support corpus composition as the main cause; exact attribution to each
removed row has not been established.

The previous installation gates also accepted an absolute fixed floor of
98% and promotion floor of 95%, without comparing the published model.
r33 passed those floors despite regressing. Installation now requires a
hash-verified published baseline and non-regression in raw labels and final
actions on all four core suites. Comparison reports bind model/dataset hashes
and the confidence threshold. Trainer manifests record input SHA-256, actual
split seed and validation fraction.

## Selected recipe

- Start from `build/pipeline/generalization-v50-train-r32.ndjson`, SHA-256
  `b7bbf3f408ef7955c1f78c402cf7f6ed78840f033dae1a85492cf9756ad9315a`.
- Add the 66 independently worded rows in
  `tools/apple-trainer/Training/classic-v51-boundaries.ndjson`: 22 each in
  zh/en/ja, including paired promotion/transaction, pickup/transit and
  ticketing/transport/scam distinctions.
- Use `prepare_classic_candidate.py`, selecting all supplement labels and
  passing every path returned by `sift_pipeline.holdout_test_sets()` as a
  `--holdout`. All 27 sets, totaling 1,957 rows, remain isolated by exact and
  digit-normalized signatures. Do not train on evaluation rows.
- Run `curate_dataset.py --audit-only --strict-audit` on the resulting
  16,538-row corpus. All 53 labels retain first-class zh/en/ja coverage.
- Train multilingual Create ML MaxEnt with validation fraction 0 and seed 29.
  All *training* rows are used; selection relies on external suites rather
  than an internal score. The final corpus hash is
  `1c8a5c312717a71bbb2c967b29f5891d55a5ab7e5ecaecb6bab73c7999cf5072`.

After preparing the corpus, reproduce the guarded training/install with:

```bash
pnpm pipeline -- train-classic \
  --classic-training-input build/classic-optimization-20260920/selected-train.ndjson \
  --classic-baseline-model build/release-audit-20260920/builtins/GeneratedModels/SiftSMSClassifier.mlmodel \
  --validation-fraction-classic 0 --split-seed-classic 29 \
  --version-classic maxent-generalization-v51-full-r34 \
  --display-version-classic 1.2 --install-ios
```

The experiment used an isolated output directory to preserve previous
artifacts. Reproduction creates a new model file; bind evaluation evidence to
its new hash before release rather than assuming binary-identical serialization.

## Actual inference results

| Metric | Published r32 | Previous local r33 | Selected r34 |
| --- | ---: | ---: | ---: |
| Fixed 487, raw labels | 98.97% | 98.15% | 98.97% |
| Fixed 487, final actions | 99.18% | 98.36% | 99.18% |
| Promotion 150, raw labels | 98.00% | 96.00% | 98.67% |
| Promotion 150, final actions | 98.67% | 98.00% | 99.33% |
| Billing/card 30, raw/actions | 100% | 100% | 100% |
| Conversation 30, raw/actions | 100% | 100% | 100% |
| Additional generalization 1,237, raw | 96.69% | 96.85% | 98.06% |
| Additional generalization 1,237, actions | 99.84% | 99.27% | 100% |
| Model bytes | 495,244 | 713,876 | 538,458 |

Feizhu 14 and cruise 9 remain perfect. No benign/transactional example was
routed to junk. Of the additional per-suite raw scores, v5 loses one of 60
rows (93.33% -> 91.67%) relative to r32; its final actions remain correct.
This is inside the documented three-percentage-point allowance for secondary
generalization suites. Core suites have no regression. Stronger-looking
fixed-score candidates were rejected for broader boundary losses.

Across all 1,957 external rows, using the curation language detector:

| Raw label accuracy | r32 | r33 | r34 |
| --- | ---: | ---: | ---: |
| zh, 679 | 98.09% | 97.20% | 98.53% |
| en, 639 | 96.56% | 96.56% | 97.97% |
| ja, 639 | 97.81% | 97.97% | 98.75% |

These established regression sets were used to compare candidates. They are
leak-free with respect to training but are not a newly blinded production
sample; the results do not prove accuracy on every incoming message.

## Artifact and checks

Selected artifact SHA-256:
`37b1f48ed55c206f3a399381ba03451149dadecb82804d1fb5a803c292c1f9da`.
Display version: `1.2`. The old local r33 was backed up before installing r34.
All experiment data, twelve candidate outputs, per-suite reports, corpus audit,
and selection identity are under `build/classic-optimization-20260920/`.
The final evidence is in `selected/`.

Validation: Swift build, 250 iOS-module tests, CoreSmokeTests, three Apple
trainer tests, eleven pipeline tests, and all 143 transformer tooling tests
passed. The selected source model compiles for iOS 18. Pipeline execution
passed the published-baseline comparison and Feizhu/cruise gates. This was
local model inference and compilation, not a physical-device SMS acceptance
test or a production model publication.
