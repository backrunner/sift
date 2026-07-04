# Sift transformer trainer

Trains the **frozen multilingual Transformer variant** of the Sift SMS
classifier with [SetFit](https://github.com/huggingface/setfit) (contrastive
sentence-transformer fine-tuning + logistic head) and exports one fused
Core ML classifier.

The exported model is intentionally **not fine-tunable on device** — the iOS
app hides all local personalization UI while this variant is selected. The
classic Create ML model (`tools/apple-trainer`) remains the fine-tunable
variant.

## Artifacts

| file | purpose |
| --- | --- |
| `SiftTransformerClassifier.mlpackage` | fused body + head, Core ML classifier (`input_ids`/`attention_mask` int32 `[1, maxLength]` → label + probability dict) |
| `SiftTransformerClassifier.vocab.txt` | WordPiece vocabulary consumed by the Swift `WordPieceTokenizer` |
| `SiftTransformerClassifier.manifest.json` | metadata read by `TransformerClassifierLoader` (labels, max length, casing, version) |

Copy all three into `apps/ios/GeneratedModels/` (`--install-ios` does this) and
regenerate the Xcode project; the app's model capsule then offers the
Transformer variant.

## Backbone requirements

The on-device tokenizer implements **WordPiece** only, so pick an
mBERT/DistilmBERT-family backbone. The default is
`sentence-transformers/distiluse-base-multilingual-cased-v2` (50+ languages,
WordPiece, 512-dim embeddings). SentencePiece backbones (XLM-R/MiniLM-L12
multilingual, e5, gte, …) are rejected at startup.

Size levers for the message-filter extension's tight memory budget:

- `--quantize int8` — linear weight quantization (default is fp16)
- `--prune-vocab` — drop embedding rows for tokens never seen in the corpus
  (keeps all single-character tokens as decomposition fallback)
- `--truncate-layers N` — keep only the first N encoder layers *before*
  training so the contrastive phase adapts the remaining stack

## Device support (Apple Silicon MPS / NVIDIA CUDA / AMD ROCm)

The trainer picks the fastest available device automatically and always
exports on CPU (Core ML tracing requires it):

```bash
uv run train_setfit.py --input ... --device auto   # default: cuda → mps → cpu
uv run train_setfit.py --input ... --device mps    # force Apple Silicon GPU
uv run train_setfit.py --input ... --device cuda   # force NVIDIA CUDA or AMD ROCm
uv run train_setfit.py --input ... --device cpu
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
  uv run train_setfit.py --input ... --device auto
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

Every training run saves a resumable checkpoint (full vocabulary, body +
head) to `<out>/checkpoint` before export-time transforms like vocab pruning:

```bash
uv run train_setfit.py --input train.ndjson                  # writes <out>/checkpoint
uv run train_setfit.py --input more.ndjson \
  --resume-from ../../build/transformer-model/checkpoint     # continue training
uv run train_setfit.py --input train.ndjson --save-checkpoint off
```

## Usage

```bash
cd tools/transformer-trainer
uv sync

# full run on the multilingual public corpus
uv run train_setfit.py \
  --input ../../build/public-corpus.ndjson \
  --out ../../build/transformer-model \
  --quantize int8 --prune-vocab --truncate-layers 3 \
  --version setfit-0.1 \
  --install-ios

# fast smoke run (frozen body, logistic head only)
uv run train_setfit.py --input ../../build/public-corpus.ndjson --head-only
```

Input is the same framework-neutral `{"text": ..., "label": ...}` NDJSON the
Create ML trainer uses — build it with
`swift run SiftAppleTrainer --build-public-corpus` and/or export live samples
with `pnpm export:training`; concatenating the two files is fine (the trainer
deduplicates nothing across files, so dedupe first if you merge).

Labels are validated against `packages/taxonomy/taxonomy.json`; validation
accuracy is printed per label and recorded in the manifest.
