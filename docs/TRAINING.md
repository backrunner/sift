# Training Pipeline Guide

This is the authoritative operating guide for training the classic model and
publishing the Premium transformer model. For architecture background, see
`agents/architecture.md`; for taxonomy rules, see `docs/TAXONOMY.md`.

## 0. Prerequisites

- macOS with full Xcode 16. Create ML requires the full Xcode installation;
  `xcode-select --install` is not enough.
- `pnpm install` at the repository root.
- [uv](https://docs.astral.sh/uv) for transformer training, PII training, and
  model-level curation filters.
- Optional CloudKit server key for fetching user-submitted samples.

```bash
export CLOUDKIT_KEY_ID=<key id created in the CloudKit console>
export CLOUDKIT_PRIVATE_KEY=~/.keys/sift-ck.pem
```

## 1. One-Command Pipeline

```bash
pnpm pipeline -- all --install-ios
```

This runs `fetch-public -> fetch-remote -> curate -> train-classic ->
train-transformer`. Artifacts are written under `build/pipeline/`.
`--install-ios` installs the classic and a local bundled Premium transformer
into `apps/ios/GeneratedModels/` for device validation. Production transformer
distribution still uses the upload flow in section 2.5.
Without CloudKit credentials, `fetch-remote` skips politely; use
`--require-remote` to make missing credentials a hard failure.

Common variants:

```bash
pnpm pipeline -- all --skip fetch-remote            # Fully offline
pnpm pipeline -- all --strict-audit                 # Fail if zh/en/ja coverage is insufficient
pnpm pipeline -- curate --model-filter off          # Lightweight curation rerun without uv
pnpm pipeline -- train-transformer --device mps     # Force a training device
```

## 2. Step-By-Step

### 2.1 Fetch Data

```bash
pnpm pipeline -- fetch-public \
  --per-label 80 --core-per-label 60 --intl-per-label 16 --public-per-label 500
pnpm pipeline -- fetch-remote --cloudkit-env production
```

`fetch-public` builds synthetic seed data for all zh labels, all en/ja labels,
and core categories in es/pt/fr/de/ru/ko/id/vi/th, then downloads public
datasets.

### 2.2 Curate And Audit

```bash
pnpm pipeline -- curate --model-filter auto --strict-audit
```

Two filters run:

1. **Rule-level filter** using only the standard library: taxonomy validation,
   normalization, length limits (8-500), low-information and repetition
   heuristics, placeholder rehydration such as `{{PHONE}}` into deterministic
   synthetic values, exact and near-duplicate removal, cross-label conflict
   removal, and language allowlisting. Rehydration never attempts to recover
   the submitted original; that would be both impossible and a privacy breach.
2. **Model-level filter** with `--model-filter auto|on` and uv: a centroid
   embedding margin filter. Rows with margin < `--hard-floor` (-0.15) are
   rejected; gray-zone rows in `[hard-floor, 0)` keep the top
   `--gray-keep` share per label (70% by default); rows with margin >= 0 are
   kept. This reduces noise while retaining likely correction samples.

Outputs are `train.ndjson`, `rejected.ndjson` with rejection reasons and
margins, and `curation-report.json` with source counts, rejection counts, and
label-by-language matrices.

Audit rule: every label must have at least `--min-core-rows` rows (default 10)
in each of zh/en/ja. With `--strict-audit`, failures exit with code 2. To audit
any dataset directly:

```bash
python3 tools/transformer-trainer/curate_dataset.py \
  --inputs some.ndjson --audit-only --strict-audit
```

### 2.3 Train The Classic Model (Create ML)

```bash
pnpm pipeline -- train-classic --version-classic corpus-0.2 \
  --algorithm-classic maxent --install-ios
```

`--language auto` trains as a single language when at least 90% of the corpus is
one language; mixed corpora train language-independently. The validated default
classic architecture is Create ML MaxEnt. `bert` and `auto` are available for
comparison, but they underperformed MaxEnt on the current 50-label small SMS
dataset. Change `--split-seed-classic` when rechecking generalization; do not
trust only the default seed 42.

The automated curation stage always isolates both external holdouts before
training. For a custom candidate assembled outside `pnpm pipeline`, use the
same mandatory isolation helper:

```bash
python3 tools/apple-trainer/Scripts/prepare_classic_candidate.py \
  --base build/pipeline/mmbert-fixed-train-dense60-boundary-v3.ndjson \
  --supplement build/pipeline/synthetic-tri-180-promotion-v8.ndjson \
  --holdout tools/apple-trainer/Evaluation/classification-regressions.ndjson \
  --holdout tools/apple-trainer/Evaluation/promotion-regressions.ndjson \
  --labels promotion,carrier.promotion,transaction.message,transaction.order,transaction.points,finance.bank,finance.insurance,carrier.data_reminder,travel.ticketing,spam \
  --out build/pipeline/classic-transformer-promotion-v8.ndjson \
  --report build/pipeline/classic-transformer-promotion-v8.report.json
```

The script rejects exact and digit-normalized near duplicates before either
classic or transformer training. `maxent-boundary-v7` remains the accepted
classic baseline at 98.95% on the
fixed 474 rows. It scores 86.67% on the breadth-first 150-row promotion set;
the expanded coverage is primarily optimized for the Premium transformer.

Training prints the weakest 12 labels and the top confusion pairs. Use those
reports as the main improvement loop: add targeted templates or samples, then
retrain.

### 2.4 Train The Transformer (mmBERT -> Core ML)

```bash
pnpm pipeline -- train-transformer \
  --version-transformer mmbert-0.1 --quantize int8
```

- `--device auto` selects cuda (NVIDIA or AMD ROCm), then mps (Apple Silicon),
  then cpu. For ROCm, first install the matching PyTorch wheel, for example:
  `uv pip install torch --index-url https://download.pytorch.org/whl/rocm6.2`.
- Default backbone: `jhu-clsp/mmBERT-small`, a ModernBERT architecture with a
  metaspace BPE tokenizer. Override with `--backbone`.
- Every run writes `transformer-model/checkpoint/` and `training-report.html`
  with loss curves, per-label accuracy, and confusion pairs.
- Size controls: `--quantize int8` and `--truncate-layers N`. The BPE tokenizer
  is exported as `SiftTransformerClassifier.tokenizer.json`.
- The exported `SiftTransformerClassifier.manifest.json` includes
  `remoteArtifacts` and `downloadBytes`. `.mlpackage` is a directory package,
  so remote distribution downloads the listed files individually.
- The accepted `mmbert-boundary-v8` checkpoint keeps 99.58% fixed-set accuracy
  and reaches 98.00% on the breadth-first 150-row promotion boundary set after
  one epoch at `1e-5`. The 96 added zh/en/ja variants cover game marketplaces,
  retail, finance, carrier offers, travel, insurance, services, loans, housing,
  and semantically adjacent transaction/normal-message/scam negatives.

### 2.5 Upload The Premium Transformer Model

The app reads the manifest first when a Premium user switches to the transformer:

```text
https://sift.alkinum.io/models/SiftTransformerClassifier.manifest.json
```

After accepting a transformer training run, upload
`build/pipeline/transformer-model/` to the public directory behind that URL.
The recommended target is a Cloudflare R2 bucket exposed through a public
custom domain or Worker/Pages route.

- Recommended R2 object key prefix: `models/`.
- Public base URL used by the app: `https://sift.alkinum.io/models`.
- These must map one-to-one so
  `models/SiftTransformerClassifier.manifest.json` is publicly reachable.

Credentials must not be committed. Copy the dotenv sample and provide real
values locally or via CI secrets:

```bash
cp .env.transformer-model.example .env.transformer-model
```

The upload script loads `.env.transformer-model` from the repository root when
present. Use `--env-file /path/to/file` to choose another file or
`--no-env-file` to skip dotenv loading. The real `.env.transformer-model` file
is git-ignored and must not be committed.

Use Cloudflare R2 S3-compatible access keys for `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`, scoped to the model bucket with least privilege. First
run a dry-run to validate the manifest, hashes, and total byte size:

```bash
pnpm upload:transformer-model -- \
  --model-dir build/pipeline/transformer-model \
  --dry-run
```

Upload to R2:

```bash
pnpm upload:transformer-model -- \
  --model-dir build/pipeline/transformer-model \
  --r2-bucket "$SIFT_MODEL_R2_BUCKET" \
  --verify-http
```

If you do not want to place the account id in the environment, pass
`--r2-endpoint-url https://<account-id>.r2.cloudflarestorage.com`. If you use an
AWS profile, set `AWS_PROFILE=sift-r2` in dotenv or pass
`--aws-profile <profile>`.

You can also copy to a local publish directory:

```bash
pnpm upload:transformer-model -- \
  --model-dir build/pipeline/transformer-model \
  --dest-dir /path/to/public/models
```

Other object stores or CDNs can still use an upload command template. The script
runs the template once for the manifest and once for every `remoteArtifacts`
file, supporting `{src}`, `{path}`, `{content_type}`, and `{cache_control}`:

```bash
pnpm upload:transformer-model -- \
  --model-dir build/pipeline/transformer-model \
  --base-url https://sift.alkinum.io/models \
  --upload-command 'rclone copyto {src} r2:sift-public/models/{path}' \
  --verify-http
```

Release acceptance:

1. `--dry-run` must pass, and `upload bytes` should match the current Core ML
   export size.
2. `--verify-http` must confirm that the manifest and every artifact are
   reachable through the CDN.
3. On device, selecting transformer while not purchased should open the Premium
   purchase flow only. After purchase, selecting transformer should start the
   download. Expensive or Low Data Mode networks should show the traffic prompt.
4. Until download and checksum validation complete, the extension must keep
   using the classic model. It switches only after validation.

### 2.6 Incremental Fine-Tuning

```bash
pnpm pipeline -- finetune          # Resume the latest checkpoint, LR 1e-5
pnpm pipeline -- finetune --resume-from build/pipeline/transformer-model/checkpoint \
  --learning-rate 5e-6
```

Flow: new data -> `curate` -> `finetune`. This classification task has no
separate reward signal; the practical equivalent is confidence-tiered curation
plus low-learning-rate supervised fine-tuning. Do not introduce true RL here.

### 2.7 Optional PII Redaction Model

```bash
cd tools/pii-trainer && uv sync
uv run train_pii.py --input ../../build/pipeline/train.ndjson --install-ios
```

The app unions model detections with context-aware deterministic rules. A union
can increase false positives, so `--install-ios` refuses models below 0.90 PII
micro F1 or above 2% clean-sentence FPR on either synthetic clean rows or the
fixed `Evaluation/clean-negatives.ndjson` set. Runtime uses whole-word average
probabilities with a 0.85 threshold. If the PII model is absent, pure rules run;
see `tools/pii-trainer/README.md`.

Vehicle plates are deliberately excluded from the PII model. They are redacted
only after complete regional-format and nearby-context checks pass, with shared
positive and hard-negative fixtures covering China, Japan, Europe, the US, and
Hong Kong. This keeps generic order numbers, flight numbers, product models,
company registrations, and student enrollment identifiers visible.

The accepted `pii-boundary-v5` result is 99.66% precision, 99.09% recall,
99.37% F1, 0/498 synthetic clean false positives, and 0/45 fixed zh/en/ja
hard-negative false positives. CODE positives are synthesized only with
authentication context, while ordinary error codes, product codes, SKUs,
build identifiers, and campaign references are clean negatives. Runtime also
rejects model CODE detections without explicit verification/OTP context.

## 3. Multilingual Strategy Decision

**Decision: use one multilingual model, not per-language models.**

- Both model stacks are naturally multilingual: Apple contextual embeddings
  cover writing systems, and the transformer uses an mmBERT multilingual
  encoder. With 50 classes and tens to hundreds of samples per class, sharing
  category semantics across languages gives better per-language accuracy than
  splitting the data into thinner per-language models.
- Mixed-language SMS messages are handled naturally by one model. Three models
  would also triple size, extension memory pressure, switching logic, and
  maintenance cost.
- If one language lags, use the training report to locate weak labels, add
  templates or samples for that language, and run `finetune`. Do not split the
  model first.

**Sample language tagging is required and implemented in two places.** Device
locale is not text language, so the client uses `NLLanguageRecognizer` when
submitting samples and writes `textLanguage`. Curation-side language detection
is a fallback and cross-check. The field powers language quotas, audit matrices,
and per-language evaluation.

## 4. Artifact Inventory

| File | Destination |
| --- | --- |
| `build/pipeline/train.ndjson` | Input for both trainers |
| `build/pipeline/apple-model/SiftSMSClassifier.{mlmodel,manifest.json}` | App and extension classic model |
| `build/pipeline/transformer-model/SiftTransformerClassifier.{mlpackage,tokenizer.json,manifest.json}` | Upload to `https://sift.alkinum.io/models/` for Premium on-demand download |
| `build/pipeline/transformer-model/checkpoint/` | Fine-tuning starting point |
| `build/pipeline/transformer-model/training-report.html` | Training report |
| `build/pii-model/SiftPIIDetector.*` | Optional app PII model |

After installing app artifacts, run `cd apps/ios && xcodegen generate` so the
Xcode project sees them. Transformer artifacts must not be committed to
`apps/ios/GeneratedModels/`; for local bundled debugging, edit `project.yml`
temporarily and remove that change before committing.
