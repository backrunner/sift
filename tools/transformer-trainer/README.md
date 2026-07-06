# Sift transformer trainer

Trains the **frozen multilingual Transformer variant** of the Sift SMS
classifier with supervised mmBERT fine-tuning and exports one fused Core ML
classifier.

The exported model is intentionally **not fine-tunable on device** — the iOS
app hides all local personalization UI while this variant is selected. The
classic Create ML model (`tools/apple-trainer`) remains the fine-tunable
variant.

## Artifacts

| file | purpose |
| --- | --- |
| `SiftTransformerClassifier.mlpackage` | fused body + head, Core ML classifier (`input_ids`/`attention_mask` int32 `[1, maxLength]` → label + probability dict) |
| `SiftTransformerClassifier.tokenizer.json` | Hugging Face BPE tokenizer consumed by the Swift `BPETokenizer` |
| `SiftTransformerClassifier.manifest.json` | metadata read by `TransformerClassifierLoader` (labels, max length, casing, version, remote file list, download size) |

Do **not** ship these files inside the app. Upload the manifest, tokenizer,
and every file inside the `.mlpackage` to the public model CDN with
`upload_transformer_model.py`; the iOS app downloads them only when a Premium
user explicitly switches to the Transformer variant.

## Backbone requirements

The default backbone is `jhu-clsp/mmBERT-small` (ModernBERT architecture,
metaspace BPE tokenizer). The iOS runtime now supports the legacy WordPiece
artifact shape and the mmBERT BPE tokenizer JSON; new transformer exports use
`tokenizerKind: "bpe"` in the manifest.

Size levers for the message-filter extension's tight memory budget:

- `--quantize int8` — linear weight quantization (default is fp16)
- `--truncate-layers N` — keep only the first N encoder layers before training
  for smaller spike builds

The old SetFit trainer remains as `train_setfit.py` for comparison and
rollback; the pipeline calls `train_mmbert.py`.

## Device support (Apple Silicon MPS / NVIDIA CUDA / AMD ROCm)

The trainer picks the fastest available device automatically and always
exports on CPU (Core ML tracing requires it):

```bash
uv run train_mmbert.py --input ... --device auto   # default: cuda → mps → cpu
uv run train_mmbert.py --input ... --device mps    # force Apple Silicon GPU
uv run train_mmbert.py --input ... --device cuda   # force NVIDIA CUDA or AMD ROCm
uv run train_mmbert.py --input ... --device cpu
```

- **Apple Silicon (M-series)**: works out of the box with the default PyPI
  torch wheels (arm64). The script sets `PYTORCH_ENABLE_MPS_FALLBACK=1` so
  the few ops MPS lacks fall back to CPU instead of aborting. Requires
  macOS 12.3+.
- **AMD ROCm (Linux)**: PyTorch's ROCm builds surface as the `cuda` device
  (`torch.version.hip` is set), so `--device auto`/`cuda` just works — but
  the PyPI default wheels are CPU/CUDA only. Install the ROCm build into the
  project venv first:

  ```bash
  uv sync
  uv pip install --upgrade torch --index-url https://download.pytorch.org/whl/rocm6.2
  uv run train_mmbert.py --input ... --device auto
  ```

  The startup line confirms what was picked, e.g.
  `device: cuda (AMD Radeon RX 7900 XTX, AMD ROCm/HIP 6.2)`.
- **Core ML export** (`coremltools`) runs on macOS or Linux; the final
  `.mlpackage` is identical regardless of the training device.

## Dataset curation & quality filtering

`curate_dataset.py` merges corpora (synthetic + public + user-contributed
CloudKit exports), drops low-quality rows, and audits coverage. It is what
the automated pipeline runs between "fetch" and "train":

```bash
# rule tier only (stdlib, no ML deps)
python3 curate_dataset.py --inputs a.ndjson b.ndjson \
  --out train.ndjson --rejected rejected.ndjson --report report.json --audit

# + embedding label-noise filter (drops rows closer to another label's centroid)
uv run curate_dataset.py --inputs ... --out train.ndjson --model-filter on

# coverage audit only; non-zero exit if any label lacks zh/en/ja rows
python3 curate_dataset.py --inputs train.ndjson --audit-only --strict-audit
```

Rule tier: taxonomy validation → NFC/whitespace normalization → length
bounds → junk heuristics (low-information, repetitive, too-few-words,
placeholder-only) → **sanitizer-placeholder rehydration** (`{{PHONE}}`,
`{{CODE}}`, … become plausible fake values so contributed samples match the
raw-SMS distribution seen at inference) → exact + near-duplicate dedupe →
cross-label conflict removal → language allowlist.

Model tier (`--model-filter auto|on`): embeds every row with the backbone,
builds per-label centroids, and rejects rows whose own-label cosine trails
the best other-label cosine by more than `--noise-margin` — the classic
mislabeled-submission case.

## Checkpoints & resuming

Every training run saves a resumable checkpoint to `<out>/checkpoint` before
Core ML export-time transforms:

```bash
uv run train_mmbert.py --input train.ndjson                  # writes <out>/checkpoint
uv run train_mmbert.py --input more.ndjson \
  --resume-from ../../build/transformer-model/checkpoint     # continue training
uv run train_mmbert.py --input train.ndjson --save-checkpoint off
```

## Usage

```bash
cd tools/transformer-trainer
uv sync

# full run on the multilingual public corpus
uv run train_mmbert.py \
  --input ../../build/public-corpus.ndjson \
  --out ../../build/transformer-model \
  --quantize int8 \
  --version mmbert-0.1

# validate and upload to the public model URL used by the iOS app
export SIFT_TRANSFORMER_MODEL_BASE_URL=https://sift.alkinum.io/models
export SIFT_MODEL_R2_BUCKET=sift-public
export SIFT_MODEL_R2_PREFIX=models
export CLOUDFLARE_ACCOUNT_ID=...
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
python3 upload_transformer_model.py \
  --model-dir ../../build/transformer-model \
  --dry-run
python3 upload_transformer_model.py \
  --model-dir ../../build/transformer-model \
  --r2-bucket "$SIFT_MODEL_R2_BUCKET" \
  --verify-http

# fast export smoke run
uv run train_mmbert.py --input ../../build/public-corpus.ndjson \
  --num-epochs 0 --max-rows 80 --max-length 8 --truncate-layers 1
```

Input is the same framework-neutral `{"text": ..., "label": ...}` NDJSON the
Create ML trainer uses — build it with
`swift run SiftAppleTrainer --build-public-corpus` and/or export live samples
with `pnpm export:training`; concatenating the two files is fine (the trainer
deduplicates nothing across files, so dedupe first if you merge).

Labels are validated against `packages/taxonomy/taxonomy.json`; validation
accuracy is printed per label and recorded in the manifest.
