# Sift training pipeline

The pipeline drives dataset refresh, quality curation, both model trainings,
and a fresh Transformer quantization tournament. Selecting and publishing the
Transformer remain separate release steps because they require evidence from
real devices and an offline Ed25519 key:

```bash
pnpm pipeline -- all --install-ios            # everything, fresh
pnpm pipeline -- all --skip fetch-remote      # offline (no CloudKit creds)
pnpm pipeline -- curate --model-filter off    # re-run one stage, light mode
pnpm pipeline -- finetune                     # resume last checkpoint, low LR
pnpm pipeline -- train-transformer \
  --resume-from build/pipeline/transformer-model/checkpoint
pnpm pipeline -- quantize-transformer \
  --version-transformer signal-v4-generalization-v50-r32-full \
  --release-sequence 4 --minimum-app-build 19 \
  --maximum-app-build 2147483647
# Add --qat-model w4a32-block16-qat=/path/to/qat.mlpackage when PTQ quality fails.
```

Stages: `fetch-public` → `fetch-remote` → `curate` → `augment` → `prune` →
`train-classic` → `train-transformer` → `distill-transformer` → `quantize-transformer`. Each stage validates its own
inputs, so any stage can be re-run in isolation; artifacts live under
`build/pipeline/`.

- `fetch-remote` needs `CLOUDKIT_KEY_ID` + `CLOUDKIT_PRIVATE_KEY`; without
  them it skips politely (pass `--require-remote` to fail instead).
- `fetch-public` defaults to `--public-source-policy curated`; opt into
  undeclared-license sources only for explicit research runs.
- `curate` enforces data quality (see
  `tools/transformer-trainer/curate_dataset.py`) and audits that every
  taxonomy label has enough zh / en / ja rows; `--strict-audit` turns
  coverage gaps into pipeline failures. It also rejects exact and
  digit-normalized collisions against every configured external holdout before any
  model can train or be installed. Both train stages repeat the collision check
  and refuse stale or manually replaced `train.ndjson` files.
  A deterministic source/label/language cap prevents one corpus from
  dominating a leaf; reports include provenance and template concentration.
- `augment` reads `train.curated.ndjson`, applies only versioned label/language
  transformations and reviewed boundary rows, rejects every external holdout,
  template-deduplicates the result, and writes `train.augmented.ndjson` plus
  `augmentation-report.json`.
- `prune` embeds the augmented corpus and removes same-label repetitions only
  within the same language at cosine similarity 0.96 or higher. Reviewed
  boundary rows always survive, observed/public rows outrank generic synthetic
  wrappers, and every label/language bucket keeps at least 20 rows. A
  same-language cross-label pair at or above 0.96 fails the stage rather than
  silently entering both classes. The final output is `train.ndjson`; removals
  and counts are recorded in `pruning-rejected.ndjson` and
  `pruning-report.json`.
- `train-classic` uses Create ML MaxEnt by default (`--algorithm-classic
  maxent`) because it is the validated high-accuracy, tiny-model baseline for
  the current 53-label SMS corpus; pass `--algorithm-classic bert` or `auto`
  only for comparison runs. Use `--split-seed-classic` to repeat validation
  on alternate deterministic per-label holdout splits.
- `train-transformer` fine-tunes `jhu-clsp/mmBERT-small` by default, picks
  cuda (NVIDIA/ROCm) → mps (Apple Silicon) → cpu automatically, always writes
  a resumable checkpoint, and emits
  `training-report.html` (loss curve, per-label accuracy, confusion pairs).
- `distill-transformer` freezes that teacher checkpoint and trains the
  release-qualified 12-layer student with temperature 2, distill alpha 0.7,
  boundary loss 2, and seed 32 before quantization.
- `quantize-transformer` regenerates the FP32 source baseline, W8A32, and
  supported W4A32 candidates. Historical A16 profiles remain readable but are
  not release-eligible because the current Core ML graph computes in FP32.
  candidates for the current checkpoint. Unsupported activation-quantized
  combinations are not generated. It never reuses the previous release's
  winner. W4 QAT candidates are considered only when their paired PTQ
candidate fails quality gates.
  Reports and release selection include the billing/card holdout in addition
  to fixed, promotion, and conversation metrics.
- `finetune` is the incremental path after new data lands: it resumes the
  latest checkpoint with a low learning rate (default 1e-5) instead of
  retraining from scratch. When labels are added, shared classifier rows are
  migrated by label id and only new rows start from fresh weights.

The published `signal-v4-generalization-v50-r32-distilled-12l` target uses the
current 53-label contract and is isolated at the Sift 1.4 channel
`channels/v3/SiftSignalModel.channel.json`; its signed release entry is
`releaseSequence = 4` with `minimumAppBuild = 19`. The legacy Sift 1.3 channel
`channels/v2/SiftSignalModel.channel.json` is frozen at sequence 3, so build
16--18 continue to receive only the 52-label-compatible model. Build 15 and
earlier must never receive the expanded label contract.

Tool requirements per stage: `swift` (fetch-public, train-classic), `pnpm`
(fetch-remote), `uv` (prune, train-transformer, and curate when the model filter
is enabled). The orchestrator itself is stdlib-only Python 3.10+.

## Transformer release gate

For every candidate report under
`build/pipeline/transformer-model/quantization-tournament/reports`, run
`TransformerRuntimeBenchmark` and the device-hosted production
`MessageFilterEngine` stress suite on the physical iPhone available for the
release. Merge that evidence into the report first, then generate the
distillation gate so its student report hash covers the final evidence:

```bash
python3 tools/transformer-trainer/record_device_metrics.py \
  --report build/pipeline/transformer-model/quantization-tournament/reports/w4a32-block16-ptq.report.json \
  --runtime-benchmark /path/to/runtime-benchmark.json \
  --extension-evidence /path/to/extension-evidence.json
```

```bash
python3 tools/transformer-trainer/check_distillation_gate.py \
  --teacher-report /path/to/teacher.report.json \
  --student-report build/pipeline/transformer-model/quantization-tournament/reports/w4a32-block16-ptq.report.json \
  --out build/pipeline/transformer-model/quantization-tournament/distillation-gate-w4a32-block16.json
```

After every candidate has device evidence, select the winner. Selection fails
instead of falling back to FP16 when no int8/int4 candidate passes:

```bash
pnpm pipeline -- select-transformer --release-sequence 4 --minimum-app-build 19
```

For a distilled source, selection also requires a passing gate bound to the
candidate's report, artifact hash, and teacher/student provenance. Gate files
named `distillation-gate*.json` beside the reports are discovered automatically;
pass `--distillation-gate /path/to/gate.json` (repeatable) when they are stored
elsewhere. A missing or stale gate rejects the candidate.

Publish only the selected candidate. The publisher verifies the report SHA,
artifact SHA, distillation gate, profile, all quality/action/device gates and Ed25519 signatures
before writing the immutable release and mutable channel pointer:

```bash
python3 tools/transformer-trainer/upload_transformer_model.py \
  --model-dir build/pipeline/transformer-model/quantization-tournament/candidates/w4a32-block16-ptq \
  --selection build/pipeline/transformer-model/quantization-tournament/selected-candidate.json \
  --r2-bucket "$SIFT_MODEL_R2_BUCKET" --verify-http
```
