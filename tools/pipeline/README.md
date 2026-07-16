# Sift training pipeline

One command drives the full loop — dataset download/refresh, CloudKit sample
export, quality curation + coverage audit, both model trainings, and Core ML
installation into the iOS app:

```bash
pnpm pipeline -- all --install-ios            # everything, fresh
pnpm pipeline -- all --skip fetch-remote      # offline (no CloudKit creds)
pnpm pipeline -- curate --model-filter off    # re-run one stage, light mode
pnpm pipeline -- finetune                     # resume last checkpoint, low LR
pnpm pipeline -- train-transformer \
  --resume-from build/pipeline/transformer-model/checkpoint
```

Stages: `fetch-public` → `fetch-remote` → `curate` → `train-classic` →
`train-transformer`. Each stage validates its own inputs, so any stage can be
re-run in isolation; artifacts live under `build/pipeline/`.

- `fetch-remote` needs `CLOUDKIT_KEY_ID` + `CLOUDKIT_PRIVATE_KEY`; without
  them it skips politely (pass `--require-remote` to fail instead).
- `curate` enforces data quality (see
  `tools/transformer-trainer/curate_dataset.py`) and audits that every
  taxonomy label has enough zh / en / ja rows; `--strict-audit` turns
  coverage gaps into pipeline failures. It also rejects exact and
  digit-normalized collisions against both fixed external holdouts before any
  model can train or be installed. Both train stages repeat the collision check
  and refuse stale or manually replaced `train.ndjson` files.
- `train-classic` uses Create ML MaxEnt by default (`--algorithm-classic
  maxent`) because it is the validated high-accuracy, tiny-model baseline for
  the current 50-label SMS corpus; pass `--algorithm-classic bert` or `auto`
  only for comparison runs. Use `--split-seed-classic` to repeat validation
  on alternate deterministic per-label holdout splits.
- `train-transformer` fine-tunes `jhu-clsp/mmBERT-small` by default, picks
  cuda (NVIDIA/ROCm) → mps (Apple Silicon) → cpu automatically, always writes
  a resumable checkpoint, and emits
  `training-report.html` (loss curve, per-label accuracy, confusion pairs).
- `finetune` is the incremental path after new data lands: it resumes the
  latest checkpoint with a low learning rate (default 1e-5) instead of
  retraining from scratch.

Tool requirements per stage: `swift` (fetch-public, train-classic), `pnpm`
(fetch-remote), `uv` (train-transformer, and curate when the model filter is
enabled). The orchestrator itself is stdlib-only Python 3.10+.
