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
| `SiftSignalModel.mlpackage` | fused body + head, Core ML classifier (`input_ids`/`attention_mask` int32 `[1, maxLength]` → label + probability dict) |
| `SiftSignalModel.tokenizer.siftbpe` | compact memory-mapped BPE tokenizer consumed by the Swift `BPETokenizer` |
| `SiftSignalModel.manifest.json` | signed v2 release metadata read by the model loader (ABI, compatibility, quantization, validation, labels, remote file list) |

Do **not** ship these files inside the app. Upload the manifest, tokenizer,
and every file inside the `.mlpackage` to the public model CDN with
`upload_transformer_model.py`; the iOS app downloads them only when a Premium
user explicitly switches to the Transformer variant.

## Backbone requirements

The default backbone is `jhu-clsp/mmBERT-small` (ModernBERT architecture,
metaspace BPE tokenizer). Transformer exports and the iOS runtime use only the
compact `.siftbpe` artifact with `tokenizerKind: "bpe"` in the manifest.

Size levers for the message-filter extension's tight memory budget are evaluated
as a tournament, not selected from validation accuracy alone. The checked-in
`quantization-profiles.json` includes W8A16 and supported W4A16
block-16/block-32 profiles. Unsupported activation-quantized combinations are
not generated. A W4 QAT profile is only enabled when its PTQ predecessor fails
the quality gates.

Every quantized candidate also runs the production Swift MessageFilter artifact
suite with the versioned trilingual readable cases. A readable-case mismatch
fails the tournament before device metrics or candidate selection can proceed.

Provide QAT-trained FP16 exports with repeated
`--qat-model PROFILE_ID=/path/to/model.mlpackage` arguments. The selector only
considers each QAT report when its exact PTQ predecessor fails quality gates;
it never uses QAT to bypass a passing, smaller PTQ candidate.

Generate the FP16 baseline and all candidates after training:

```bash
pnpm pipeline -- train-transformer --version-transformer signal-v1
pnpm pipeline -- quantize-transformer --version-transformer signal-v1
```

The FP16 source package targets iOS 18. Generate only quantization profiles
that Core ML can execute for this graph. The current tournament keeps W8A16
per-channel and W4A16 per-block candidates; unsupported activation-quantized
combinations are not generated. Candidate reuse binds the Core ML Tools
version, profile, tokenizer, calibration sample set, and max sequence length.

Complete each candidate report with evidence from the physical iPhone that is
available for the release. Do not invent a separate A12 result when no A12
device is available:

```bash
./run_ios_device_benchmark.sh \
  --device <device-udid> \
  --candidate ../../build/pipeline/<run>/candidates/<profile> \
  --output ../../build/device-evidence/<device>/<profile> \
  --allow-provisioning-updates

python3 record_device_metrics.py \
  --report ../../build/pipeline/transformer-model/quantization-tournament/reports/w8a16-channel-ptq.report.json \
  --runtime-benchmark ../../build/device-evidence/release/<profile>/runtime-benchmark.json \
  --extension-evidence ../../build/device-evidence/release/<profile>/extension-evidence.json
```

The device script never bundles the Premium model. It installs the signed host
app, copies the candidate to an App Group staging directory with `devicectl`,
then the hosted XCTest validates hashes, compiles on the iPhone, runs the
trilingual smoke cases, activates the release, and exports the runtime JSON.
The same run drives the production `MessageFilterEngine` through 30 fresh
engine loads and 10,000 warm queries. It exports
`message-filter-snapshot.json`, a content-free aggregate grouped by requested
artifact identity with latency buckets, fallback/error counts, watchdogs and
physical-footprint drift, but never sender or body.

The runtime benchmark records the process baseline before model load, then
reports average and peak physical-footprint increases. Do not treat the XCTest
host's absolute footprint as model memory. Positive memory growth is gated;
memory reclaimed by the runtime remains a signed negative change and is not
misreported as a leak. `MLComputePlan` inspection is recorded separately from
the inference peak.

Convert the device aggregate into the release-evidence schema:

```bash
python3 export_message_filter_evidence.py \
  --snapshot /path/to/DeviceEvidence/message-filter-snapshot.json \
  --runtime-benchmark /path/to/DeviceEvidence/runtime-benchmark.json \
  --output /path/to/extension-evidence.json \
  --release-sequence 1 \
  --device-model iPhone18,3 \
  --os-version 27.0 \
  --jetsam-count 0
```

The converter uses each bucket's upper bound, so the resulting percentiles are
conservative. It refuses unbounded `>=1s` samples, insufficient query counts,
fallbacks, watchdogs, errors, positive memory drift above the gate, or any
jetsam. A CPU-only release must have a matching CPU `MLComputePlan` and actual
device runtime headroom; it does not require a contradictory non-zero
accelerator trace. Accelerated releases still require their trace and stress
sign-offs.

Only after every release candidate has device evidence can the deterministic
selector run:

```bash
pnpm pipeline -- select-transformer --release-sequence 1
```

`selected-candidate.json` is SHA-bound to the winning report. The publisher
refuses to upload any candidate without that file, valid Ed25519 signing key,
and all fixed/promotion/action/device gates.

Before collecting iPhone evidence, a candidate can be installed into the local
App Group store and exercised through the production Swift tokenizer,
`MessageFilterEngine`, rules, action/subaction mapping, and the manifest's
compute plan:

```bash
cd ../../apps/ios
swift run MessageFilterArtifactTests \
  --model ../../build/pipeline/<run>/candidates/<profile>/SiftSignalModel.mlpackage \
  --tokenizer ../../build/pipeline/<run>/candidates/<profile>/SiftSignalModel.tokenizer.siftbpe \
  --manifest ../../build/pipeline/<run>/candidates/<profile>/SiftSignalModel.manifest.json \
  --fixed ../../tools/apple-trainer/Evaluation/classification-regressions.ndjson \
  --promotion ../../tools/apple-trainer/Evaluation/promotion-regressions.ndjson \
  --output ../../build/pipeline/<run>/candidates/<profile>/production-dynamic-validation.json \
  --install-dynamic --readable-cases --inspect-compute-plan
```

`--install-dynamic` uses the same staging, Core ML compilation, trilingual smoke,
active/previous rotation, and installed runtime loader as production. It is a
development-only unsigned local install; CDN publication still requires the
signed manifests and `selected-candidate.json`. A Mac benchmark is useful for
cross-checking memory accounting, but the release gate uses the available
physical iPhone.

- `--truncate-layers N` — keep only the first N encoder layers before training
  for smaller spike builds

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
  --out train.ndjson --rejected rejected.ndjson --report report.json --audit \
  --holdout ../apple-trainer/Evaluation/classification-regressions.ndjson \
  --holdout ../apple-trainer/Evaluation/promotion-regressions.ndjson

# + embedding label-noise filter (drops rows closer to another label's centroid)
uv run curate_dataset.py --inputs ... --out train.ndjson --model-filter on

# coverage audit only; non-zero exit if any label lacks zh/en/ja rows
python3 curate_dataset.py --inputs train.ndjson --audit-only --strict-audit
```

Rule tier: taxonomy validation → NFC/whitespace normalization → length
bounds → junk heuristics (low-information, repetitive, too-few-words,
placeholder-only) → **sanitizer-placeholder rehydration** (`{{PHONE}}`,
`{{CODE}}`, `{{PLATE}}`, … become plausible fake values so contributed samples
match the raw-SMS distribution seen at inference without attempting to recover
the submitted original) → exact + near-duplicate dedupe →
cross-label conflict removal → language allowlist.

The pipeline then runs `augment_dataset.py` with the versioned
`generalization-augmentation.json`. It adds only label/language-scoped semantic
replacements and reviewed boundary rows, caps additions per label, and repeats
exact/digit-normalized holdout and template-cluster checks before producing the
final `train.ndjson`.

CloudKit exports retain the device-detected `textLanguage`. Curation normalizes
that hint (`zh-Hans` → `zh`, `ja-JP` → `ja`) and only falls back to script
detection when the hint is absent, so kanji-only Japanese samples are not
rehydrated with Chinese values.

The automated pipeline always supplies both external holdouts. Exact and
digit-normalized collisions are rejected before either model can train or be
installed, and the counts appear as `holdout-exact` / `holdout-near` in the
curation report.

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
  --version signal-v1

# validate and upload only the selected candidate
cp ../../.env.signal-model.example ../../.env.signal-model
python3 upload_transformer_model.py \
  --model-dir ../../build/pipeline/transformer-model/quantization-tournament/candidates/w8a16-channel-ptq \
  --selection ../../build/pipeline/transformer-model/selected-candidate.json \
  --dry-run
python3 upload_transformer_model.py \
  --model-dir ../../build/pipeline/transformer-model/quantization-tournament/candidates/w8a16-channel-ptq \
  --selection ../../build/pipeline/transformer-model/selected-candidate.json \
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
