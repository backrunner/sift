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
`quantization-profiles.json` includes W8A32 and supported W4A32
block-16/block-32 profiles. Unsupported activation-quantized combinations are
not generated. A W4 QAT profile is only enabled when its PTQ predecessor fails
the quality gates.

The 256k mmBERT vocabulary is the largest remaining structural size lever. A
64k retained vocabulary would remove about 73.7 MB from the W8 embedding before
accounting for tokenizer savings. Treat vocabulary pruning as a new trained
checkpoint, not a post-export rewrite: retain special and byte-fallback tokens,
select tokens only from the leak-free training corpus, remap embedding rows,
fine-tune, and run the full external holdout and device tournament. Compare 96k
and 64k before trading away encoder depth with `--truncate-layers`.

For a lower-risk intermediate experiment, the explicit-only
`w8a32-channel-embedding-w4-block16-ptq` profile quantizes just the 256k x 384
token embedding to W4 while leaving the encoder at W8. Request it with
`--profile-id`; it is deliberately ineligible for release until the production
Swift holdouts and physical-iPhone cold-start, memory, and stress gates have all
been recorded. This isolates most of the size reduction of full W4 without
quantizing the attention and MLP weights that previously failed quality gates.
On macOS 27, Core ML Tools can return non-finite output for this iOS-targeted
graph with `CPU_ONLY` even when `ALL` is finite. This does not predict or replace
physical-iPhone CPU-only evidence. `--allow-experimental-macos-cpu-smoke-failure`
exists only for an explicit set of release-ineligible profiles; it still
requires the macOS `ALL` smoke, production Swift holdouts, and the physical-iPhone
gate. By itself it cannot be used for a release-eligible profile.

For a quality-only tournament whose complete output must remain unpublished,
combine that switch with `--experimental-release-ineligible-run`. Every report
then records `releaseEligible: false`, and the candidate selector rejects it
even if device metrics are later added. This permits same-holdout comparison on
a macOS/Core ML combination with a known CPU-only backend failure without
turning the exception into a release bypass.

Every quantized candidate also runs the production Swift MessageFilter artifact
suite with the versioned trilingual readable cases. A readable-case mismatch
fails the tournament before device metrics or candidate selection can proceed.

Provide QAT-trained FP16 exports with repeated
`--qat-model PROFILE_ID=/path/to/model.mlpackage` arguments. The selector only
considers each QAT report when its exact PTQ predecessor fails quality gates;
it never uses QAT to bypass a passing, smaller PTQ candidate.

Generate the FP32 source baseline and all candidates after training:

```bash
pnpm pipeline -- train-transformer --version-transformer signal-v1
pnpm pipeline -- distill-transformer --version-transformer signal-v1
pnpm pipeline -- quantize-transformer --version-transformer signal-v1
```

The source package targets iOS 18 and uses FP32 intermediates for reliable
CPU-only execution. Generate only quantization profiles that Core ML can
execute for this graph. The current tournament keeps W8A32 per-channel and W4A32 per-block candidates; unsupported activation-quantized
combinations are not generated. Candidate reuse binds the Core ML Tools
version, profile, tokenizer, calibration sample set, max sequence length, and
the exact source manifest. Quantization preserves the source training
algorithm and distillation provenance; it records a separate `quantizedAt`
timestamp instead of rewriting `trainedAt`.

## Distilled student release

The current published student is `signal-v4-generalization-v50-r32-distilled-12l`
(channel release `signal-v4-generalization-v50-r32-distilled-12l-metadata-v2`).
It was trained from a leak-free 53-label corpus with a 22-layer teacher, then
distilled to 12 layers using temperature 2 and distill alpha 0.7. The selected
W4A32 block16 PTQ artifact (W4 weight-only with FP32 compute) is 108,748,513 bytes, runs CPU-only on the physical
iPhone gate, and is compatible with app build 19 and newer. Its signed channel
entry is sequence 4; builds 16--18 continue to resolve the sequence 3 entry.
The Premium artifact is uploaded dynamically and must not be added to
`GeneratedModels/` or any Xcode resource phase.

## Historical distilled student experiment

The production Signal checkpoint can be used as a frozen teacher for a smaller,
structurally truncated student. This entry point is opt-in and never installs
or publishes the student by itself:

```bash
uv run distill_mmbert.py \
  --input ../../build/pipeline/train.ndjson \
  --teacher-checkpoint ../../build/pipeline/transformer-model/checkpoint \
  --out ../../build/pipeline/signal-distilled-12l \
  --version signal-distilled-12l \
  --truncate-layers 12 \
  --temperature 2 --distill-alpha 0.7 \
  --num-epochs 3 --batch-size 8 --learning-rate 2e-5 \
  --test-input ../../tools/apple-trainer/Evaluation/promotion-regressions.ndjson
```

The teacher, corpus, and selected taxonomy must have exactly the same output
contract (taxonomy leaves plus `__sift_abstain__`). `--taxonomy` defaults to the
current repository taxonomy. A legacy teacher experiment must pass the exact
historical taxonomy explicitly; this keeps the emitted taxonomy hash truthful
and prevents an old output head from masquerading as a current release.

Run the resulting FP16 package through the normal quantization tournament with
the fixed, promotion, billing/card, and conversation holdouts. Compare the
student report with the teacher report using an absolute two-point gate:

```bash
python3 check_distillation_gate.py \
  --teacher-report /path/to/teacher/w4a32-block16-ptq.report.json \
  --student-report /path/to/student/w4a32-block16-ptq.report.json \
  --max-loss 0.02 \
  --out /path/to/student/distillation-gate.json
```

The gate JSON includes hashes for both holdout reports and the student
artifact, plus the teacher checkpoint, layer counts, temperature, and
distillation weight. `select_quantization_candidate.py` requires this bound
passing gate for every distilled candidate (it auto-discovers
`distillation-gate*.json` beside the reports, or accepts repeatable
`--distillation-gate` paths). The uploader verifies the same hash and
provenance again; a missing, changed, or cross-wired gate cannot be published.

The student is release-ineligible until this gate, the existing Swift artifact
suite, and fresh physical-iPhone cold-start/memory evidence all pass. The
teacher checkpoint hash, student depth, temperature, and distillation weight
are recorded in the student's manifest for auditability.
The two-point student gate is absolute and applies independently to fixed,
promotion, billing/card, conversation, production action, and per-language
metrics. Passing an aggregate average cannot hide a loss greater than two
points on one boundary, and zero benign-to-junk actions remains mandatory.

The 2026-08-18 v15 teacher experiment found W4 block 32 to be the only
quantized 12-layer student that passed the absolute two-point gate. It reduced
download size from 260,548,289 bytes (FP16) to 85,948,562 bytes while matching
the teacher's fixed, promotion, billing/card, and conversation raw accuracy;
fixed action accuracy lost 0.21 points. It remains permanently ineligible for
release because it has the legacy 52-output contract (51 leaves plus
abstention), omits `government.reminder`, has no physical-iPhone evidence, and
produces non-finite `CPU_ONLY` output on the tested macOS 27/Core ML Tools 9.0
host. A publishable student must be retrained with the current 53-output
contract and pass the full device tournament again.

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
  --report ../../build/pipeline/transformer-model/quantization-tournament/reports/w4a32-block16-ptq.report.json \
  --runtime-benchmark ../../build/device-evidence/release/<profile>/runtime-benchmark.json \
  --extension-evidence ../../build/device-evidence/release/<profile>/extension-evidence.json
```

The device script never bundles the Premium model. It installs the signed host
app, copies the candidate to an App Group staging directory with `devicectl`,
then uses separate XCTest processes to compile and activate the model, run one
final-path prediction prime, and measure the next process's model load. The
exported `installation-prime.json` is the unprimed final-path cost;
`runtime-benchmark.json` is the post-prime cross-process cost. Process IDs are
included so a same-process cache hit cannot be mistaken for extension startup.
The same run drives the production `MessageFilterEngine` through 30 fresh
engine loads and 10,000 warm queries. It exports
`message-filter-snapshot.json`, a content-free aggregate grouped by requested
artifact identity with latency buckets, fallback/error counts, watchdogs and
physical-footprint drift, but never sender or body.

The runtime benchmark records model initialization, the first real inference,
their combined cold path, and the process baseline before model load, then
reports average and peak physical-footprint increases. Do not treat the XCTest
host's absolute footprint as model memory. Positive memory growth is gated;
memory reclaimed by the runtime remains a signed negative change and is not
misreported as a leak. `MLComputePlan` inspection is recorded separately from
the inference peak. Candidate selection uses the production IdentityLookup
cold-start P95 before steady-state inference latency when size and memory are
otherwise comparable.

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
  --billing ../../tools/apple-trainer/Evaluation/billing-card-regressions.ndjson \
  --conversation ../../tools/transformer-trainer/Evaluation/conversation-regressions.ndjson \
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
  --max-rows-per-source-label-language 500 \
  --holdout ../apple-trainer/Evaluation/classification-regressions.ndjson \
  --holdout ../apple-trainer/Evaluation/promotion-regressions.ndjson \
  --holdout ../apple-trainer/Evaluation/billing-card-regressions.ndjson \
  --holdout Evaluation/conversation-regressions.ndjson

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
unpruned `train.augmented.ndjson`. Base rows retain `source`, `sourceLabel`, and `language`
metadata; generated variants are marked as `augmentation:<family>`.

`prune_dataset.py` is the final corpus step. It uses the same multilingual
sentence encoder as curation to remove rows with cosine similarity >= 0.96,
but compares repetitions only within one label and one language. Reviewed
`augmentation:boundary:*` rows are protected; real/public rows are preferred
over synthetic surface wrappers; and one anchor per replacement family and
language is retained. It also performs a same-language cross-label scan and
fails closed at 0.96, so a semantic near duplicate cannot silently train two
different labels. The default floor retains at least 20 rows in every
label/language bucket.

```bash
uv run prune_dataset.py \
  --input ../../build/pipeline/train.augmented.ndjson \
  --out ../../build/pipeline/train.ndjson \
  --rejected ../../build/pipeline/pruning-rejected.ndjson \
  --report ../../build/pipeline/pruning-report.json
```

CloudKit exports retain the device-detected `textLanguage`. Curation normalizes
that hint (`zh-Hans` → `zh`, `ja-JP` → `ja`) and only falls back to script
detection when the hint is absent, so kanji-only Japanese samples are not
rehydrated with Chinese values.

The automated pipeline always supplies every configured external holdout. Exact and
digit-normalized collisions are rejected before either model can train or be
installed, and the counts appear as `holdout-exact` / `holdout-near` in the
curation report.

The curation report also records source counts, source/label/language buckets,
and template-cluster concentration. The deterministic source cap runs before
the embedding filter, preventing one large public dataset or CloudKit export
from dominating a label while preserving the core-language coverage audit.
Use a lower cap such as 160 for an explicit aggressive-pruning experiment.

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

For a narrow output-row recalibration, keep the encoder and every unrelated
classifier row frozen with `--train-label-rows`. Because every other corpus
row is still a useful hard negative, `--selected-label-loss-weight` balances
the selected labels' positive rows without discarding those negatives. The
positive and `augmentation:boundary:*` multipliers are applied
multiplicatively and recorded in the exported manifest.

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
  --model-dir ../../build/pipeline/transformer-model/quantization-tournament/candidates/w4a32-block16-ptq \
  --selection ../../build/pipeline/transformer-model/selected-candidate.json \
  --dry-run
python3 upload_transformer_model.py \
  --model-dir ../../build/pipeline/transformer-model/quantization-tournament/candidates/w4a32-block16-ptq \
  --selection ../../build/pipeline/transformer-model/selected-candidate.json \
  --r2-bucket "$SIFT_MODEL_R2_BUCKET" \
  --verify-http

# fast export smoke run
uv run train_mmbert.py --input ../../build/public-corpus.ndjson \
  --num-epochs 0 --max-rows 80 --max-length 8 --truncate-layers 1
```

The publisher writes the current app-line channel (default
`channels/v3/SiftSignalModel.channel.json`) and keeps immutable release
artifacts under versioned directories. The legacy `channels/v2` pointer is
frozen for Sift 1.3 and must not be updated with newer label contracts. Current
apps verify the signed channel and choose the release allowed by their app
build, OS, ABI, and installed release sequence. Use
`--compatible-release-manifest-url` only to bootstrap an older immutable
release into the catalog; never use `--no-preserve-channel-history` for a
production upload.

If signed metadata must be repaired without changing accepted model bytes,
publish a new release id and reuse the verified immutable artifact directory:

```bash
python3 upload_transformer_model.py \
  --model-dir ../../build/pipeline/transformer-model/quantization-tournament/candidates/w4a32-block16-ptq \
  --selection ../../build/pipeline/transformer-model/quantization-tournament/selected-candidate.json \
  --release-id signal-v4-generalization-v50-r32-distilled-12l-metadata-v2 \
  --reuse-artifacts-base-url https://sift.alkinum.io/models/releases/signal-v4-generalization-v50-r32-distilled-12l \
  --dry-run
```

This mode downloads and hash-checks every referenced public artifact, requires
the existing release sequence and compatibility boundaries to remain
unchanged, then publishes only the new manifest and channel metadata.

Input is the same framework-neutral `{"text": ..., "label": ...}` NDJSON the
Create ML trainer uses — build it with
`swift run SiftAppleTrainer --build-public-corpus` and/or export live samples
with `pnpm export:training`; concatenating the two files is fine (the trainer
deduplicates nothing across files, so dedupe first if you merge).

Labels are validated against `packages/taxonomy/taxonomy.json`; validation
accuracy is printed per label and recorded in the manifest.
