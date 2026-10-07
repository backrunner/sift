# mmBERT-lite local feasibility — 2026-10-07

This records the initial unpublished local experiments. The later iPhone study
installed an isolated filtering probe and changed its selected extension with
the device owner. Production qualification is tracked separately below.

## Objective and result boundary

Prioritize mmBERT, retain a checkpoint that can be fine-tuned with classification
labels without invoking a larger teacher on every update, and pass a local
**absolute process lifetime peak below 16,000,000 bytes** before another device
experiment. Artifact/download bytes are reported separately. Neither a small file
nor a baseline-subtracted memory delta satisfies the memory gate.

The 6-layer width-192 and width-256 mmBERT candidates pass the local memory gate
with FP32-weight Core ML NeuralNetwork exports, but external classification
quality regresses. A third candidate preserves width 384 and shrinks only the
MLP; it improves quality relative to the narrower candidates but fails memory.
**No compressed candidate jointly passed the original 16 MB local target and
quality gates.** On October 7 the device owner explicitly removed 16 MB as a
hard cutoff after the original 12-layer NeuralNetwork export completed a real
SMS query; retain that model if actual extension stability qualifies. Ordinary MLProgram execution alone would have hidden
an important restricted-loader memory increase.

## Existing implementations and training approach

- [hotchpotch/mmBERT-L4H384-pruned](https://huggingface.co/hotchpotch/mmBERT-L4H384-pruned)
  supplies a community 4-layer, width-384 mmBERT checkpoint. The card distinguishes
  pruning from subsequent fine-tuning/distillation. It retains a large vocabulary;
  pruning depth alone does not establish a 16 MB runtime.
- [hotchpotch/bekko-embedding-v1-a8m](https://huggingface.co/hotchpotch/bekko-embedding-v1-a8m)
  is a continued-trained 4-layer mmBERT derivative for retrieval. Its approximately
  8 million **active** parameters exclude the large embedding table: the total is
  approximately 106 million parameters. It is not an 8 MB SMS classifier, and
  retrieval scores do not establish Sift classification accuracy.
- [smaller-transformers](https://github.com/Geotrend-research/smaller-transformers)
  is prior work on trimming multilingual vocabularies. Direct ModernBERT support
  was not assumed.

The Sift experiment inherits weights from the existing local 6-layer mmBERT
checkpoint, which itself has a distillation history. It does **not** demonstrate
that a model trained entirely from random initialization matches mmBERT. This
round uses ordinary supervised cross-entropy training without teacher logits.
The saved Hugging Face model/tokenizer/config can be used as `--resume-from` for
future supervised updates. The trainer starts a new optimizer/scheduler; this is
continued fine-tuning, not bit-identical resumption of an interrupted optimizer.

The product objective remains 53-way classification (52 taxonomy leaves plus
abstention). Neither embedding retrieval nor language generation is introduced.
Pretrained language representations are initialization for that classifier.

## Data and structural reduction

The corpus has 19,210 rows after isolating all 27 external suites (1,957 rows),
including exact, digit-normalized, and template comparisons. The deterministic
seed-32 split contains 17,313 training rows and 1,897 internal validation rows.
Vocabulary statistics use only the 17,313 training rows, not either validation or
external evaluation. The resulting 24,187-token BPE vocabulary retains special
tokens, byte fallback, observed characters, and merge ancestors.

Width reduction preserves whole 64-dimensional attention heads, slices residual
channels consistently, and preserves both halves of the gated MLP. The first
candidate retains 6 layers, reduces hidden width 384 to 192, heads 6 to 3, and
intermediate width 1,152 to 384. It has 6,905,525 total parameters. Selection uses
source-weight magnitudes, not external labels. Training uses six epochs, batch
size 32, learning rate 5e-5, and boundary loss weight 2, without teacher supervision.

## Local memory method

`MacMemoryProbe.swift` links the production `MessageFilterCore` implementation and
uses `BPETokenizer`, `MappedTokenEmbedding`, `TransformerTextClassifier`, CPU-only
execution, autorelease pools, and the kernel's lifetime peak physical-footprint
counter. Each process performs 1,000 inferences over short/long zh/en/ja examples.

Normal and restricted runs are separate processes. The restricted profile is:

```scheme
(version 1)
(allow default)
(deny iokit-open (iokit-user-client-class "IOSurfaceRootUserClient"))
```

This reproduces the IOSurface error seen during the phone investigation and a
large MLProgram loading-memory increase. It is **not** the complete IdentityLookup
sandbox, the iPhone allocator, or an enforced 16 MB OS memory limit. Passing is
local feasibility evidence only. Device peak, termination behavior, cold launch,
and actual SMS filtering remain separate gates.

Artifacts are compiled and read from the Mac's internal temporary volume. On the
external project volume, `.mappedIfSafe` copied the 17 MB original tokenizer and
inflated the process baseline. Those external-volume reports are retained but
excluded from comparisons intended to approximate the phone's mapped tokenizer.

Three fresh process runs are recorded per mode for the new candidates. These
include the first observed process and subsequent processes; they do not promise
a completely purged OS/Core ML cache on every run. Long and short multilingual
inputs are covered, but this is not an exhaustive memory bound for arbitrary text.

## Initial measurements

All sizes below use decimal MB. Peak is absolute process peak, including loading,
not model-only allocation. New width-192 rows show the maximum of three processes
per mode; historical comparison rows show the recorded local process.

| Candidate / format | Download MB | Normal peak MB | Restricted peak MB | External raw labels |
| --- | ---: | ---: | ---: | ---: |
| Existing 2-layer width-384, W8 mapped MLProgram | 82.92 | 19.38 | 47.97 | 1,850 / 1,957 |
| Width-192, W8 mapped MLProgram | 6.650 | 16.34 | 37.03 | 1,849 / 1,957 |
| Width-192, W4 finite16 mapped MLProgram | 5.774 | 15.78 | 32.28 | 1,835 / 1,957 |
| Width-192, FP32 mapped NeuralNetwork | 13.426 | 12.57 | 12.29 | 1,851 / 1,957 |
| Width-192, FP16-weight mapped NeuralNetwork | 8.833 | 13.54 | 13.54 | 1,851 / 1,957 |
| Width-192, INT8-weight mapped NeuralNetwork | 6.623 | 17.42 | 18.38 | 1,849 / 1,957 |

Quantized storage does not imply a smaller runtime: expansion and retained runtime
allocations can reverse the comparison. The NeuralNetwork exports use encoder
weights from the same fine-tuned checkpoint and a mapped W4 embedding table.
FP16 and INT8 NeuralNetwork conversions replace the FP32-minimum attention mask
sentinel with -10,000 before conversion to keep masked attention finite.

Published Signal's raw-label baseline on the same 27 suites is 1,916 / 1,957
(97.905%). The initial width-192 FP32 NeuralNetwork candidate scores 94.584%,
with fixed-set 480 / 487 and promotion-set 149 / 150. Its production Swift engine
action score is 1,934 / 1,957, including one benign/transaction message routed to
junk. This quality regression blocks selection even though its memory passes.

The unquantized width-192 MLProgram scores 1,855 / 1,957; the large accuracy gap
already exists before weight quantization. It cannot be blamed entirely on INT4.

A second memory pass also streams all 1,957 external texts through the production
classifier after the 1,000 short/long examples, without retaining the entire
dataset in memory. Across three normal and three restricted processes, this is
17,742 inferences with zero inference failures and a maximum lifetime peak of
12,796,648 bytes for the width-192 FP32 NeuralNetwork candidate. This stronger
local check still does not establish its accuracy or phone-extension behavior.

## Wider checkpoint and execution-format controls

A second supervised candidate retains 6 layers and increases width to 256, with
4 attention heads and MLP intermediate width 512 (10,206,773 total parameters).
It uses the same training recipe and training-only vocabulary selection. Its
FP32 NeuralNetwork export reaches 12.731 MB normal / 12.698 MB restricted peaks,
but its raw-label score is also 1,851 / 1,957. The error sets differ substantially;
equal aggregate accuracy does not imply identical behavior. The larger artifact
is 21.424 MB, despite its measured runtime fitting the 16 MB process budget.
Its FP16-weight export is 13.316 MB on disk, but one normal process reached
16.745 MB, so it fails the repeated-process memory gate.

Changing only the execution format for the existing width-384, 6-layer checkpoint
produces maximum normal/restricted peaks of 18.203 / 17.581 MB with FP32 weights.
The 12-layer checkpoint reaches 24.823 / 24.790 MB. These control exports restore
encoder weights from their training checkpoints and reuse mapped W4 embeddings;
they are not byte-identical to the published quantized artifacts.

Reducing the existing 6-layer model's input cap from 96 to 64 tokens does not
reliably fix memory: maximum normal/restricted peaks remain 18.318 / 17.925 MB.
It scores 1,909 / 1,957 raw labels and 1,954 / 1,957 Swift actions, with three
truncated external samples and no benign/transaction-to-junk errors. The memory
gate fails, so this length reduction is not selected.

A third supervised candidate keeps all 384 residual/embedding dimensions and all
6 attention heads, reducing only the MLP intermediate width from 1,152 to 384.
It retains 6 layers and the same 24,187-token vocabulary (15,654,197 parameters).
The same six-epoch label-only recipe yields 1,875 / 1,957 raw labels (95.810%) in
both mapped NeuralNetwork precision exports, fixed-set 481 / 487 and promotion
147 / 150. The FP32 export's Swift action score is 1,940 / 1,957, with zero
benign/transaction-to-junk cases. This improves over width pruning but still
regresses against the published baseline.

Its FP32 artifact is 32.782 MB with maximum normal/restricted process peaks of
19.006 / 16.794 MB. FP16-weight storage reduces the artifact to 19.962 MB but
maximum normal/restricted peaks are 16.843 / 19.449 MB. Both fail the strict
16,000,000-byte memory gate. There were no inference errors in the six processes
per precision variant; absence of inference errors is not a memory pass.

These comparisons support continuing development of a reusable mmBERT-lite
checkpoint and the low-memory export path. They do not establish that routine
label-only fine-tuning after arbitrary structural pruning can recover the
published model's accuracy. Teacher-assisted recovery remains an optional
foundation-building technique, not a requirement for every future data update.

## Additional contract checks

HF versus production Swift tokenizer comparison covers all 1,957 holdout texts
and 9 added edge cases. There are 6 mismatches: one holdout text and five edge
cases (empty text, whitespace, combining marks, Thai, and literal special tokens).
Both accuracy with the HF tokenizer and final actions with the production Swift
tokenizer are recorded; exact tokenizer parity is not claimed. A production
candidate needs these mismatches addressed or an explicit aligned tokenization
contract before qualification.

The current signed Signal release contract requires the previously qualified
12-layer distillation recipe. That is an application release policy, not a
requirement of Transformers or Apple. A future supervised mmBERT-lite release
needs an intentional contract/ABI update and artifact validation; it must not be
made eligible by falsifying `algorithm` or distillation provenance.

## Local evidence and continuation

All model files, checkpoints, full reports, and exploratory scripts are local and
ignored under `build/diagnostics/sms-filter-20261007/`. No model artifact is added
to Git. Principal files:

- `prepare_mmbert_lite.py`: vocabulary and structural pruning, with source hash
  and channel/old-token-ID provenance in each `preparation.json`.
- `mmbert-lite-l6-h192-i384/finetuned/checkpoint`: reusable HF checkpoint.
- `mmbert-lite-l6-h256-i512/finetuned/checkpoint` and
  `mmbert-lite-l6-h384-i384/finetuned/checkpoint`: wider supervised comparisons.
- `export_mmbert_lite.py`, `export_lite_legacy.py`: unpublished export variants.
- `evaluate_mmbert_lite.py`: CPU-only raw-label evaluation across all 27 suites.
- `MacMemoryProbe.swift`, `run_lite_local16.py`, `deny-iosurface.sb`: local probe.
- `local16/*.json` and `*.log`: exact artifact hashes, byte peaks, failures, and
  loading/prediction stage samples.
- `mmbert-lite-l6-h192-i384/*/all-holdouts.json` and `all-actions.json`: per-suite
  label results and actual Swift routing results.

Further supervised training starts from the saved checkpoint, for example:

```sh
rtk proxy tools/transformer-trainer/.venv/bin/python \
  tools/transformer-trainer/train_mmbert.py \
  --input /path/to/holdout-isolated-training.ndjson \
  --resume-from build/diagnostics/sms-filter-20261007/mmbert-lite-l6-h192-i384/finetuned/checkpoint \
  --out /path/to/new-candidate --version NEW_VERSION \
  --num-epochs 6 --batch-size 32 --learning-rate 5e-5 \
  --boundary-loss-weight 2 --quantize fp16 --device mps --seed 32
```

This produces a training candidate, not a signed release or a memory-qualified
export. The trainer's historical `--quantize fp16` option still exports FP32
MLProgram compute; the measured NeuralNetwork exports are a separate step.


## Physical-device follow-up

The isolated probe runs in a real IdentityLookup extension on iPhone 17,
iOS 27.0.1 (24A446), with CPU-only execution. Persisted device OSLog is the
source of evidence: the live pymobiledevice3 stream omitted custom log entries,
so absence from that stream was not evidence that a query had never arrived.
The probe always returns `.none` for real SMS and is not production filtering.

- Width-192 NeuralNetwork: actual SMS on October 7 at 21:52:32 completed with
  lifetime peak 8,128,088 bytes; six synthetic zh/en/ja cases in the extension
  reached 8,062,552 bytes. Quality still blocks this compressed candidate.
- Original 12-layer NeuralNetwork with mapped W4 embeddings: two capabilities
  probes completed at 22:16 and 22:19. Peak reached 18,712,176 bytes.
- A real SMS query at 22:19:53 completed in 38.98 ms, with 4,671,208 bytes
  current footprint. The same process remained alive in the subsequent device
  process inventory. No corresponding memory-limit termination was observed.
- Full 12-layer candidate: 1,931/1,957 external raw labels, 1,956/1,957 production
  Swift actions, zero benign/transaction-to-junk errors. Fixed 484/487 raw,
  promotion 150/150, billing 30/30, conversation 30/30. The standard action suites
  and all 17 readable cases pass. Agreement with the unquantized reference is
  99.8565% on the four standard suites.

The exact tested package SHA-256 is
`5e7db0cb2e17b210532d240ad4cd1d21926e1e740f396ec78e03fd17e8f61092`.
Its 171,886,849-byte download is distinct from the process footprint. FP32 encoder
storage is intentional: FP16-weight conversion increased the measured local
peak to approximately 35 MB. No new teacher training is required for this export.

A separate community Bekko 4-layer foundation was fine-tuned using only the
isolated training corpus. Its FP32 mapped NeuralNetwork reached 1,915/1,957 raw
labels and 1,943/1,957 Swift actions, including one legitimate-message-to-junk
error. It is not selected. Segmented exports remain exploratory and are not part
of the chosen 12-layer runtime.

The full production-engine stress run subsequently completed 30 model reloads
and 10,000 warm classifications, with zero failures and a 19,891,944-byte absolute
peak. Separate Sift 1.5 (32) App Group installation, priming and runtime tests
also passed. See [the selected 12-layer release evidence](signal-nn12-release.md)
for the exact stress window, initial memory growth, compatibility and limitations.
