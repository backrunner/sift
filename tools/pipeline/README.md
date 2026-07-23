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
  --version-transformer signal-v2-boundary-v15 --release-sequence 2 \
  --minimum-app-build 9 --maximum-app-build 2147483647
# Add --qat-model w4a16-block16-qat=/path/to/qat.mlpackage when PTQ quality fails.
```

Stages: `fetch-public` → `fetch-remote` → `curate` → `augment` → `train-classic` →
`train-transformer` → `quantize-transformer`. Each stage validates its own
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
  template-deduplicates the result, and writes the final `train.ndjson` plus
  `augmentation-report.json`.
- `train-classic` uses Create ML MaxEnt by default (`--algorithm-classic
  maxent`) because it is the validated high-accuracy, tiny-model baseline for
  the current 51-label SMS corpus; pass `--algorithm-classic bert` or `auto`
  only for comparison runs. Use `--split-seed-classic` to repeat validation
  on alternate deterministic per-label holdout splits.
- `train-transformer` fine-tunes `jhu-clsp/mmBERT-small` by default, picks
  cuda (NVIDIA/ROCm) → mps (Apple Silicon) → cpu automatically, always writes
  a resumable checkpoint, and emits
  `training-report.html` (loss curve, per-label accuracy, confusion pairs).
- `quantize-transformer` regenerates FP16, W8A16, and supported W4A16
  candidates for the current checkpoint. Unsupported activation-quantized
  combinations are not generated. It never reuses the previous release's
  winner. W4 QAT candidates are considered only when their paired PTQ
candidate fails quality gates.
  Reports and release selection include the billing/card holdout in addition
  to fixed, promotion, and conversation metrics.
- `finetune` is the incremental path after new data lands: it resumes the
  latest checkpoint with a low learning rate (default 1e-5) instead of
  retraining from scratch.

Tool requirements per stage: `swift` (fetch-public, train-classic), `pnpm`
(fetch-remote), `uv` (train-transformer, and curate when the model filter is
enabled). The orchestrator itself is stdlib-only Python 3.10+.

## Transformer release gate

For every candidate report under
`build/pipeline/transformer-model/quantization-tournament/reports`, run
`TransformerRuntimeBenchmark` and the device-hosted production
`MessageFilterEngine` stress suite on the physical iPhone available for the
release. Merge that evidence into the report:

```bash
python3 tools/transformer-trainer/record_device_metrics.py \
  --report build/pipeline/transformer-model/quantization-tournament/reports/w8a16-channel-ptq.report.json \
  --runtime-benchmark /path/to/runtime-benchmark.json \
  --extension-evidence /path/to/extension-evidence.json
```

After every candidate has device evidence, select the winner. Selection fails
instead of falling back to FP16 when no int8/int4 candidate passes:

```bash
pnpm pipeline -- select-transformer --release-sequence 1
```

Publish only the selected candidate. The publisher verifies the report SHA,
artifact SHA, profile, all quality/action/device gates and Ed25519 signatures
before writing the immutable release and mutable channel pointer:

```bash
python3 tools/transformer-trainer/upload_transformer_model.py \
  --model-dir build/pipeline/transformer-model/quantization-tournament/candidates/w8a16-channel-ptq \
  --selection build/pipeline/transformer-model/quantization-tournament/selected-candidate.json \
  --r2-bucket "$SIFT_MODEL_R2_BUCKET" --verify-http
```
