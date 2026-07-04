# Sift PII trainer

Trains the **optional on-device Core ML PII detector** used by the app's
sanitizer. Sanitization runs on two legs:

1. **Rules (always on, the floor)** — deterministic regex/NSDataDetector
   redaction in `PrivacySanitizer` (phone, URL, email, 身份证/护照, bank
   card, order/pickup/verification codes, amounts, addresses, names).
2. **Model (this trainer, optional)** — a token-classification model that
   widens recall on messy formats the rules miss. The Swift side **unions**
   both legs before redacting, so an immature model can never make results
   worse than rules-only. Ship it only when it beats the rules on your eval.

## How it works

Training data is synthesized: carrier sentences from the SMS corpus receive
fake phone numbers / ID cards / emails / addresses / names at random word
boundaries with exact span labels (30% of sentences stay clean). A WordPiece
backbone (`distilbert-base-multilingual-cased` by default, truncated to 2
encoder layers) is fine-tuned for per-token tagging, then exported as
`logits [1, seq, tags]` with the same vocab format the Swift
`WordPieceTokenizer` consumes.

## Usage

```bash
cd tools/pii-trainer
uv sync

uv run train_pii.py \
  --input ../../build/pipeline/train.ndjson \
  --samples 20000 --epochs 2 \
  --quantize int8 \
  --install-ios          # copies SiftPIIDetector.* into apps/ios/GeneratedModels
```

Device support matches the other trainers: `--device auto` picks
cuda (NVIDIA CUDA / AMD ROCm builds) → mps (Apple Silicon) → cpu, and export
always runs on CPU. `PYTORCH_ENABLE_MPS_FALLBACK=1` is set automatically.

Artifacts (all three required; the app silently stays rules-only when absent):

| file | purpose |
| --- | --- |
| `SiftPIIDetector.mlpackage` | token-classification logits |
| `SiftPIIDetector.vocab.txt` | WordPiece vocabulary (pruned by default) |
| `SiftPIIDetector.manifest.json` | tags, max length, casing, version |

The model ships only with the main app (not the message-filter extension —
the extension never sanitizes). Size with the defaults (2 layers + pruned
vocab + int8) lands around a few dozen MB; tune `--truncate-layers`,
`--prune-vocab`, `--quantize` as needed.
