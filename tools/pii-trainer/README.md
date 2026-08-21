# Sift PII trainer

Trains the **optional on-device Core ML PII detector** used by the app's
sanitizer. Sanitization runs on two legs:

1. **Rules (always on, the floor)** — deterministic regex/NSDataDetector
   redaction in `PrivacySanitizer` (phone, URL, email, identity documents, bank
   card, vehicle plates, order/pickup/verification codes, amounts, addresses,
   names). Vehicle plates are intentionally rules-only: a broad token model is
   not allowed to bypass the regional format and context checks.
2. **Model (this trainer, optional)** — a token-classification model that
   widens recall on messy formats the rules miss. The Swift side **unions**
   both legs before redacting, so an immature model can never make results
   worse than rules-only. Ship it only when it beats the rules on your eval.

## How it works

Training data is synthesized: carrier sentences from the SMS corpus receive
fake phone numbers / ID cards / emails / addresses / names at
random word boundaries with exact span labels (50% of sentences stay clean by
default). A WordPiece backbone (`distilbert-base-multilingual-cased` by default,
truncated to 2 encoder layers) is fine-tuned for per-token tagging, then exported as
`logits [1, seq, tags]` with the same vocab format the Swift
`WordPieceTokenizer` consumes.

The reviewed synthetic feedback set
`Evaluation/redaction-regressions.ndjson` adds cloud account/resource IDs,
nicknames, and contextual QQ/WeChat/Weibo/Xiaohongshu/Douyin/Kuaishou/Zhihu,
LINE/Telegram/Discord/WhatsApp/Facebook/Instagram/TikTok/Twitter/X handles
(including explicit `@handle` forms) in zh/en/ja, together with matched
product/build/quantity negatives. It contains
no CloudKit text or real user values and is split into independent train/eval
rows. The loader fails closed on malformed spans or any `{{...}}` marker.
Each normal run also adds 2,000 freshly generated contextual hard examples
(`--contextual-redaction-samples`) with 25% matched clean negatives and repeats
the reviewed train split eight times. This gives the feedback patterns enough
weight to affect the model without leaking the independent eval split.

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

The trainer reports PII micro precision/recall/F1 and clean-sentence
false-positive rate. Evaluation includes the fixed multilingual hard-negative
set under `Evaluation/clean-negatives.ndjson`. `--install-ios` is gated by
`--minimum-pii-f1` (0.90) and `--maximum-clean-fpr` (0.02), using the same 0.85
non-PII confidence gate as the iOS detector (`--inference-threshold`).
It also reports the fixed contextual-redaction F1/FPR and refuses
`--install-ios` unless `--minimum-redaction-f1` (0.90) and
`--maximum-redaction-clean-fpr` (0.02) pass. Sanitizer tokens are an
intermediate export representation; reverse-redaction replaces them with
deterministic synthetic values before any model examples are encoded.

Vehicle-plate accuracy is gated separately by Swift sanitizer regressions. The
shared `Evaluation/plate-positives.ndjson` fixture covers China, Japan, Europe,
the US, and Hong Kong; `clean-negatives.ndjson` contains plate-shaped flight,
order, product, registration, and enrollment identifiers that must remain
visible. The same fixed set includes comma-grouped points, scores, participant
counts, and similar non-monetary quantities. Positive amount synthesis covers
grouped zh/en/ja currency formats such as `￥2,345.67`, `$2,345.67`, and
`2,345円`.

Every run writes `quality-report.json` before the install gate. Failed
candidates therefore retain auditable F1/FPR results even though
their Core ML artifacts are not installed.

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
