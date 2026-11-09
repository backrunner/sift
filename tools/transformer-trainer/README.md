# Sift transformer trainer

## Current research data and retained models (2026-11-01)

Use `experiments/signal-current-research.json` for current research pointers.
The retained models are the two original SAM0.005 replicas in
`signal-sam-retained-v33-{321,322}.json`; v21 remains the rollback. Historical
selection descriptions below do not supersede this retention decision.

The current approved corpus is
`tools/apple-trainer/Training/signal-filter-policy-v47.json`: 3,469 rows with
2,916 strict normal targets, 256 strict harmful targets and 297 commercial set
targets. Two ambiguous existing-coupon reminders are quarantined. The user now
accepts non-harmful promotion/junk ambiguity; normal-to-promotion and normal-to-junk
errors stay separate, and harmful content routed to promotion remains a miss.
`run_approved_signal.py` requires an explicit `filterPolicyMode` (`grouped` or
`strict-control`) and external Swift policy epoch selection for this corpus;
it cannot silently train the new corpus with the old target objective.
The policy wrapper uses the same loss in the ordinary pass, SAM second pass
and full-gradient probe. External state audits use `audit_filter_policy_v47.py`.
No v47 continuation has run, and the retained SAM models are unchanged.
See [the v47 review](../../docs/engineering/signal-filter-policy-v47-20261101.md).

The previous approved corpus was
`tools/apple-trainer/Training/signal-data-review-v46-r2.json`: 3,471 rows after
excluding nine context-ambiguous junk labels and fourteen inputs containing
fabricated short URLs, plus one source-backed GBP amount repair. This approves
the corpus, not a newly trained model. The four-arm study used the earlier
frozen 3,472-row version; its final one-row exclusion and amount repair were
not silently added during training and have not been retrained in this study.
The v46 revision preserves original evaluation scores, keeps valid difficult
cases, and reports revised inputs and denominators separately. Its twelve
authored replacement messages are development diagnostics, not real final data.
The final historical source audit is explicitly post-hoc: fifteen additional
rows with unresolved labels or damaged inputs are excluded from the 2,509-row
diagnostic, and six marketing messages receive source-backed amount repairs.
Original metrics and preregistered acceptance remain unchanged.
See [the v46 review](../../docs/engineering/signal-data-review-v46-20261031.md).

The four-arm weighting study uses the immutable
`signal-data-review-v46-r1-protocol.json` and `run_review_trial_v46r1.py`, with
explicit profiles and fresh output directories. Revision r1 isolates training
weight lookup from ordinary evaluation; the initial failed run is preserved.
No recipe, sample, label, or acceptance criterion changed in that repair.

## Historical research selection (2026-10-28)

`experiments/signal-current-research.json` now selects the SHA-pinned A checkpoint
in `experiments/signal-best-balanced-v10.json`. This accepts a small external
fine-label accuracy decline for better development junk recall, following the
user's revised tradeoff. A/B have tied junk recall; A has one fewer legitimate
promotion entering junk. The model remains research-only, with six total
non-junk-to-junk errors across 2,476 inspected rows and no fresh >=90% final.
See [the comparison and averaging diagnostic](../../docs/engineering/signal-balanced-selection-20261028.md).
The linked A method profile records the historical run from C; its original
inputs were intentionally scrubbed during v13 review. A new
continuation from A needs a new grouped development cohort and bounded protocol.

The subsequent [v11 continuation/LLRD audit](../../docs/engineering/signal-llrd-continuation-20261028.md)
completed two fixed600 runs from A on 2,878 reviewed rows with a newly grouped
52-row development cohort. LLRD0.9 was already active and actual optimizer peaks
were verified. Quarter LR did not improve recall; both new runs failed old junk
recall vetoes, so A remains selected. `generalization_validation.action_metrics`
now reports `nonSpamToJunk`, `promotionToJunk` and `spamPrecision` alongside the
historical service-only `benignToJunk` count. V11 development is now inspected
regression evidence, not a final test. Do not extend these trials or sweep it.

## Reviewed data enrichment and source-isolation correction v16

`Training/signal-enrichment-v16.json` under the Apple trainer seals **3,295**
training rows: the reviewed2,942 unchanged, plus173 newly reviewed public SMS
and180 separately attributed authored zh/en/ja rows. Of404 public candidates,
158 were rejected; another73 accepted public rows and54 independent authored
rows form development127. The first-class language/label coverage audit passes.
No new row exceeds the96-token context. Public and authored metrics must be
reported separately; Japanese development is authored only.

WSPR campaign IDs are not message IDs. V16 groups the full raw source through
actual registrable hosts (offline pinned Public Suffix List, including private
suffixes), URL-masked text families and NUS contributors. Prior accepted AND
rejected candidate groups are excluded, and .65 character-trigram Jaccard
checks remove near-overlapping new families. No SMS destination is fetched.
The corrected source graph exposes dependence in v15 final140, so
`experiments/signal-public-v15-integrity.json` disables its acceptance use.
Its bytes and gold are unchanged and it remains unscored; **unscored is not
the same as source-independent**. A new independent final cohort is still needed.

One preregistered run uses `experiments/signal-enrichment-v16.json`, from A with
fresh AdamW, last4 layers, LLRD0.9, effective batch128, clip5 and correct-teacher
replay. The budget is at most48 epochs/1,248 updates, with joint plateau
monitoring and separate full-gradient probes. This is a reviewed data study
with a longer bounded schedule, not a clean ablation of data alone.
The run stopped at joint loss plateau on epoch47/update1,222 with no eligible
epoch. New dev127 accuracy improves81.89% ->91.34% (public73:83.56% ->93.15%),
but old overall2528 falls94.58% ->91.81%, false junk remains3 rather than the
target maximum2, and confirmed normal FedEx clearance regresses to junk.
**A remains selected; the new checkpoint is terminal diagnostic only.**
See [the completed v16 report](../../docs/engineering/signal-enrichment-v16-20261028.md)
and [data audit](../../docs/engineering/signal-enrichment-v16-data-audit.json).

## Historical public evaluation and bounded method study v15

The [v15 report](../../docs/engineering/signal-generalization-v15-20261028.md)
reserves a new public development80 and unscored final140 after source,
contributor, host, template and possible SMS-campaign checks. The v16 corrective
audit above supersedes its claim of independent source grouping. This adds
**evaluation data only**; training remains the unchanged2,942-row v13r2 corpus.
New WSPR SP24 source attribution and the pre-inference support appendices are
recorded in `Evaluation/public-generalization-v15.json` under the Apple trainer.
Annotation is AI-assisted and the cohort is predominantly English.

Original A scores70.0% raw, junk11/16 and four all-non-junk-to-junk errors on
this new development set. Two preregistered24-epoch/552-update trials—effective
batch128 with clip5, versus rank4 attention LoRA with a frozen encoder
base—both fail every epoch's joint selection gates. Their terminal raw scores
are67.5% each. LLRD0.9 remains active. **A remains selected; no old-external
score rescues these trials, and the reserved final remains unscored.**

`low_rank_adaptation.py` uses no additional PEFT dependency and merges adapters
back into the standard53-label checkpoint. Unit tests exercise an actual tiny
ModernBERT save/reload. The full trial also verifies80/80 development-label
agreement after merge, unchanged standard state-dict keys and bit-identical
frozen lower weights. This is local PyTorch evidence, not Core ML/device proof.
Both runs are budget-limited, not strict gradient convergence certificates.

Use `run_approved_signal.py --profile experiments/signal-generalization-v15-a-large-batch.json`
or the corresponding `b-lora` profile with a new `--out` for protocol replay;
do not treat reruns as fresh trials or use the now-inspected development set
for an unlimited sweep. `evaluate_generalization_v15.py` checks frozen input
hashes and now refuses final scoring because the corrective source audit failed;
the earlier development/old-external/overall-FP and atomic single-use guards
remain in place. Further work prioritizes
independent training families, consistent intent labels and reviewed zh/ja
coverage rather than copying these evaluation errors into training.

## Gradient convergence and longer training v14

The short v13r2 run stopped at update360 with convergence monitoring disabled;
it was budget-limited, not a convergence certificate. One longer run on the
identical reviewed data now stops at the joint training/development plateau at
epoch47/update4324, selecting epoch34 by development macro F1/action gates.
Authored fine72 rises to91.67% (Chinese22/24), while old overall2528 falls
to91.81% versus A94.58%. **Original A remains selected.**

`--gradient-probe-every 1` measures full-corpus unclipped gradients before
training and each epoch without changing training RNG or loader ordering.
`--convergence-require-training-plateau` requires six full-training objective
plateau checks in addition to the development monitor. Gradient RMS is reported
separately: the terminal deterministic proxy does not pass its1e-4 diagnostic
threshold. A16-replica audit of the actual dropout/R-Drop/KD/action objective
finds mean RMS0.00011184 versus estimated noise RMS0.00007068, supporting a
noise-scale plateau rather than proving zero expected gradient.

Use `audit_training_gradients.py --protocol RUN/protocol.json --state
RUN/training-state.pt --out NEW_AUDIT.json --replicates 4 --optimizer-replicates 4`
to inspect an unfolded state. Add `--selected` to audit its eligible best
parameters rather than its terminal parameters. Default stdout is JSON;
`--verbose` sends loading diagnostics to stderr. Clipped optimizer-input means
and raw full-data gradients are deliberately separate. Audits never step an
optimizer. `plot_convergence.py` renders a standalone SVG/PNG from the summary
using Matplotlib (which can run in a separate `uv --with matplotlib` environment).

See [the convergence report and curves](../../docs/engineering/signal-convergence-v14-20261028.md).
This is an inspected-development diagnostic, not a fresh final or release.

## Loss-driven continuation v19

`--loss-tail-epochs 12 --loss-tail-max-epochs 48 --loss-tail-lr-ratio .1
--loss-tail-patience 6` adds a bounded continuation phase to a linear schedule.
The nominal `--num-epochs`/`--max-updates` budget decays to 10% of each group's
peak LR, retaining the LLRD and head ratios. At the nominal boundary, training
extends in 12-epoch blocks, up to 48 additional epochs. It does not reset AdamW
or the scheduler at each extension.

This mode requires an epoch-by-epoch full-training probe, resumable state,
development monitoring, and `--skip-export`. After the nominal boundary, six
full-training objectives must fall within `max(.001, .005 * window_max)`.
The controller then halves every LR and requires six **new** plateau checks.
The objective includes the parameter anchor and excludes decoupled AdamW
weight decay. A budget cap is explicitly reported as unconverged; a loss plateau
does not prove zero gradient or a global minimum. Gradient diagnostics remain
separate. Sustained development NLL divergence still stops the study.

Development macro F1 and the action gates select the retained checkpoint across
all completed epochs. A later, lower training loss never replaces that rule.
The terminal optimizer/controller state remains separate from the selected
checkpoint; interrupted runs resume only under the identical frozen contract.
The v19 profile uses the evidence-reviewed v18 corpus and a fresh optimizer from
A, so it is not an exact continuation of v17 or a causal scheduler ablation.

## URL data and hard-label weighting v20

The sealed v20 corpus adds 120 reviewed original synthetic messages: 72 ordinary
business notices with links, 24 legitimate promotions and 24 explicit fraud
contrasts, equally divided across zh/en/ja. Every new URL fixture appears with
all three actions. Reserved hosts are fictional, not real-message provenance or
reputation evidence. The 36 separately reserved URL diagnostics have different
workflows/hosts and are not an independent final acceptance set.

`--replay-hard-label-mode uniform` keeps hard CE at coefficient 1 for every
reviewed label and adds `alpha * T² * KL` only where the correct-teacher gate
allows it. The default `mixed` behavior is unchanged: eligible agreement rows
use `(1-alpha) * CE + alpha * T² * KL`, while disagreements use CE. Uniform mode
requires the correct-teacher gate; an incorrect teacher cannot override gold.
This changes loss scale as well as CE's relative emphasis, so inspect clipping
and generalization and do not compare raw loss magnitudes between modes.

The v20 protocol fixes three runs: original data/mixed, added data/mixed, and
the identical added data/uniform. All use the same initialization, seed,
27 updates per epoch and LR schedule. Only spent development199 selects epochs
and the arm; old regressions and URL diagnostics can veto the selected model.

## Full review and fine-label study v13

The current data contract is `Training/signal-reviewed-v13.json` (revision 2),
relative to the Apple trainer. Every one of the 2,950 predecessor rows was read:
161 were deleted, 220 received coherent body repairs, 108 were relabeled and
three had language metadata corrected. Three additional review decisions were
reversed after checking the existing voice-usage rule. Another 153 explicitly
authored zh/en/ja training rows produce 2,942 approved rows. All 53 outputs
retain at least ten rows per core language. This is AI-assisted review, not
independent human certification. No new public dataset was fetched in v13.

The hash-only checkpoint ownership index permits precisely reviewed exclusions,
relabels and body replacements while rejecting unreviewed omissions/changes.
Unchanged historical rows use replay; new and corrected rows use hard labels.
Deleted/repaired old bodies and adjudicated wrong labels are blocked from
training re-ingestion. Frozen evaluation labels and model A remain unchanged.

Two LR trials and one fixed annotation-correction verification completed, with
LLRD0.9 and at most 360 updates each. On 72 authored fine-label development rows,
revision 2 improves raw accuracy from 79.17% to 86.11%. On existing 2,528
regressions it drops from 94.58% to 91.93%, while all non-junk-to-junk errors
increase from six to seven. **A remains selected.** V13 is an approved data
candidate, not an approved replacement model; its development set is now spent.
See [the review and measured results](../../docs/engineering/signal-reviewed-training-v13-20261028.md).

## Historical approved v8 continuation

These historical inputs have been superseded and physically scrubbed. Their
original dependency hashes intentionally no longer verify. Do not rerun old
v8/v9/v11/v12 corpus builders or restore retired bodies to reproduce a score.
`run_approved_signal.py` and the pipeline now require an explicit study profile
(`--profile` / `--signal-study-profile`); there is no implicit v8 continuation.
The original C action-head/R-Drop checkpoint is frozen separately under
`build/signal-best-frozen-20261028/` as the rollback. It is **not release-qualified**.
The extended v8r2 snapshot regressed on the external suites and remains rejected;
it does not replace original C even though its development action score rose.

That historical revision had 2,758 rows, complete >=10-per-label zh/en/ja coverage,
at most two generated rows per template, and 872 public-origin rows. Other
sources are explicitly generated/authored. Random sender/suffix/emoji additions
and duplicate `#number` padding were removed from generation. Public-service
application slots are typed, synthetic yen amounts are whole, and broadband
bills use `carrier.billing`. Review is AI-assisted, not independent native or
human certification.

Retired sample bodies were physically removed from legacy training packages and
derived training caches. Hash-only retirement rules prevent re-ingestion;
curation also rejects known role/URL/currency/billing defects without writing
discarded bodies to the rejection sink. Frozen Evaluation/development/final
sets remain unchanged. **Old experiment input hashes describe historical data
that was intentionally deleted; old repair/reproduction commands are retired.**
The standalone approved corpus is authoritative and does not require deleted
quarantine files.

The fixed profile allows up to 5,000 new optimizer updates, checks development
NLL and macro F1 each epoch, and stops after six non-improving checks once
1,500 updates have completed. Three clearly divergent NLL checks may stop it
earlier. Eligible checkpoint selection still requires benign-to-junk <=2 and
spam recall 1.0; convergence is monitored even when no eligible epoch exists.
Stochastic gradient norms/clipping are diagnostics, not proof of a global or
local optimum. A falling regularized training objective alone does not justify
more training when validation worsens.

The old C checkpoint has **no AdamW state**. Its first continuation is an
explicit weights-only new stage with a new schedule. New epoch-boundary
`training-state.pt` files atomically retain trainable parameters (before action
head folding), AdamW moments, scheduler, loader/CPU/MPS RNG, selection snapshots
and convergence counters. Resume an interrupted identical plan with
`--signal-resume-state /path/to/training-state.pt` and a fresh study output.
Changed corpus, teacher, frozen weights, method or schedule is rejected. A plan
already stopped by convergence or exhausted updates cannot be silently resumed;
an intentional new weights-only stage must be declared. The CPU dropout/R-Drop
interruption test is bitwise identical to uninterrupted training; this is not
a cross-device determinism claim.

These studies use the already inspected 215-row development set. They do not
establish a new independent >=90% test result. Do not install/export a failed
research checkpoint or reuse the spent 135-row final for parameter searches.

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

## Reviewed correction replay

For continual correction experiments, `train_mmbert.py --replay-teacher PATH`
adds a frozen local teacher on replay rows. Repeat
`--replay-new-source-prefix PREFIX` for each reviewed synthetic correction
family. Those rows use hard labels without a teacher veto; other rows combine
hard-label loss and temperature-scaled teacher KL. Label order and tokenizer
IDs must match exactly. Keep real submissions and every external regression
set out of the corpus with the normal exact/digit-normalized isolation guard.

`--replay-alpha` controls preservation (default 0.9), and
`--replay-temperature` defaults to 2. `--train-last-layers N` freezes token
embeddings and lower encoder layers while updating the final N layers, final
normalization and head. It is separate from classifier-row-only tuning and
does not truncate the model. Start with full replay, compare every existing
suite, and retain new false-positive cases as regressions. The training summary
records source checkpoint hashes, source prefixes and the input hash.
`--replay-new-loss-weight` can strengthen reviewed corrections separately from
the general boundary weighting, which also applies to older replay boundaries.

Replay tuning requires `--skip-export` and cannot install a model. An independently
verified candidate can be exported with `export_neuralnetwork.py
--training-summary PATH`: this rebuilds mapped INT4 embeddings from the actual
trained checkpoint, verifies the compact tokenizer identity, strips inherited
signatures and clears old quality/device evidence. Do not copy the old mapped
embedding file after training has changed embedding weights. A mapped-precision
training experiment can instead initialize embeddings from the real mapped
rows and freeze them; verify the exported embedding hash remains identical.

The result remains unsigned and release-ineligible. Compare the exported Core
ML model and production Swift actions to the published artifact, including
confidence/fallback behavior, before considering physical-device qualification.
Checkpoint accuracy does not establish exported or IdentityLookup behavior.

Reviewed evaluation expectations are explicit, hash-checked overlays. Keep the
legacy files intact and materialize a separate view for both baseline and
candidate:

```bash
python3 tools/pipeline/review_evaluation.py \
  --dataset tools/apple-trainer/Evaluation/classification-regressions.ndjson \
  --reviews tools/apple-trainer/Evaluation/classification-label-review-v1.json \
  --out build/reviewed-evaluation/classification-regressions.ndjson
```

Run from the repository root. Retain legacy scores alongside reviewed scores;
this helper does not change pipeline release gates or install any model. The
October 27 review corrects three monetary carrier balances and one merchant
debit under the existing taxonomy; each keeps its transactional action.
See `docs/engineering/cloudkit-service-reinforcement-20261027.md` for current
candidate results and incomplete checks.

## Experimental mapped FP16 compute

CloudKit-only expansion can be reproduced with the reviewed
`cloudkit-augmentation.json` replacement rules. It intentionally adds only
small semantic variants of observed carrier, promotion, finance, government,
and loan wording; it does not inject the broad boundary catalog. Keep the
result separate until a model review accepts the new rows.

`export_mapped_precision.py` lowers an existing mapped W4A32 model without
changing its tokenizer, embedding rows, sequence length, layers, or labels.
Run it with the trainer venv, from this directory:

```bash
.venv/bin/python export_mapped_precision.py \
  --source ../../build/diagnostics/mapped-embedding-20260905/fp16-scales \
  --output ../../build/experiments/signal-mapped-finite16 \
  --profile finite16
.venv/bin/python validate_mapped_embeddings.py \
  --source /path/to/qualified-original-w4a32 \
  --candidate ../../build/experiments/signal-mapped-finite16 \
  --checkpoint /path/to/local-student-checkpoint \
  --output ../../build/experiments/finite16-holdouts.json
```

`linear16` lowers only linear operations. `mixed16` also lowers surrounding
operations while keeping normalization, softmax, matrix multiplication, and
attention-score tensors in FP32. Both introduce precision-conversion nodes.
`finite16` replaces the shared attention-mask sentinel (FP32's minimum value)
with -10,000 before lowering all eligible operations to FP16.
`finite16norm32` additionally keeps normalization and softmax in FP32.
The finite sentinel avoids conversion to negative infinity and the resulting
non-finite softmax on fully masked padding-query rows. The exporter rejects a
changed graph if the sentinel is missing or used outside mask selection.
This changes numerical behavior; label agreement alone does not certify it.

All profiles clear validation scores and signatures and remain
`releaseEligible: false`. They must pass the production Swift action/readable
suite and physical-iPhone measurements before release qualification. The
current optimization target is **less than 20,000,000 bytes of absolute process
peak footprint**, including transient loading allocations, and approximately
150 ms from tokenizer initialization through the first classification. Record
multiple fresh process IDs and the exact artifact hash. A compiled-model cache
may be prepared during installation, but first-specialization and cached-load
results must be reported separately. Neither XCTest-host footprint deltas nor
Mac results establish the IdentityLookup extension's absolute memory budget.

The September 5 experiment and its outstanding device gate are recorded in
[`docs/engineering/signal-under20-experiment.md`](../../docs/engineering/signal-under20-experiment.md).

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

Every training run saves model/tokenizer weights to `<out>/checkpoint` before
Core ML export-time transforms. `--resume-from` initializes those weights for a
new fine-tuning job: **Adam moments, update count and the learning-rate schedule
restart**. It is not an exact continuation of an interrupted optimizer run.

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
`channels/v4/SiftSignalModel.channel.json`, Sift 1.6/build 35+) and keeps immutable release
artifacts under versioned directories. The legacy `channels/v2` pointer is
frozen for Sift 1.3; `channels/v3` is frozen for Sift 1.4/1.5. New releases
(sequence 9+) belong to v4 and require minimum app build 35. Current
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
# Reviewed Signal corpus continuation (2026-10-27)

`review_signal_corpus.py` applies explicit source/text/old-label decisions and
quarantines unreviewed coarse sources. New public material goes through
`import_reviewed_public.py` schema v2, which preserves official splits and
checks all official test families, not just selected test examples. See the
[review report](../../docs/engineering/signal-corpus-review-20261027.md) for
reproduction, annotation scope and measured results. The current reviewed
candidate is not release eligible.

Pipeline train/distill/quantize/finetune accepts
`--signal-review-directory build/signal-corpus-review-20261027`; this selects
the reviewed corpus and pins its decisions and all holdouts. Classic corpus
selection is unchanged. `--replay-only-correct-teacher` optionally disables
teacher KL on retained gold-label disagreements; reviewed correction sources
always use hard labels. This prevents a frozen teacher from overriding gold,
but is not a substitute for reviewing that gold.

## Optimizer and source-repair controls

The bounded 2026-10-28 semantic experiment retains the previous grouped AdamW
configuration (encoder `2e-5`, classifier `4e-5`, layer decay `.9`, linear warmup
`.08`) as an experimental starting point, not a release-qualified checkpoint.
See `experiments/signal-semantic-reviewed-20261028.json`. All trials initialize
from original r33 weights; no rejected repair checkpoint is reused.

`--action-loss-weight .3` enables a zero-initialized additive action head with
auxiliary cross-entropy using the taxonomy's resolved actions, including leaf
overrides and abstention. Its leaf logits are `W_leaf h + W_action[action] h`.
After restoring a development-selected epoch (if one exists), the head is folded
back into one standard linear classifier. Development predictions must agree
before checkpoint saving. This is a training parameterization and supervision
experiment, not a claim to reproduce a published hierarchical architecture.

`--rdrop-alpha 1` averages the two dropout-pass supervised/replay losses and adds
per-row symmetric KL. Both distributions receive gradients; reviewed source
weights apply to the complete loss. R-Drop needs two student forwards during
training and one at inference. Its default is zero. Neither option changes
tokenization, encoder dimensions, the 53 outputs or the runtime ABI. Published
literature results do not establish SMS or device performance for these trials.

The historical builder's inputs have now been deleted. Use the approved entry
at the top of this README. The historical builder quarantined the mixed
legacy generated spam pool and applies the hash-pinned public content review
before adding complete zh/en/ja service/offer/fraud scenario triplets. It excludes
protected development and external families and refuses input drift. This is
AI-assisted review, not independent human/native-speaker annotation. The existing
215-row development set is already inspected; it is not a fresh final holdout.

Count generated data across provenance prefixes, not just `synthetic:`. The
9,014-row corpus still has at least 89.18% generated/authored rows. A separate
fixed-parameter data check uses `balance_semantic_sources.py --out NEW_DIR`:
it preserves the 144 reviewed contrast rows and caps other non-public sources
jointly per label/language (core 12, others 4), using deterministic source
round-robin. All non-public/unknown provenance counts against that budget.
The historical 3,248-row result had 878 public-origin rows plus one reviewed historical
finance row; the builder's `publicReviewedCount=879` names that protected
reviewed-source cohort, not 879 independently certified natural messages.
Its corpus report describes preparation time; later training is recorded
separately in `experiments/signal-source-balanced-20261028.json` and the run
summary. The three architecture trials use the 9,014 rows throughout.

The default `--optimizer-policy grouped` excludes one-dimensional norm/bias
parameters from AdamW decay and excludes every frozen parameter from the
optimizer. `--head-lr-multiplier` separates the classifier/head rate;
`--layer-lr-decay` applies top-down decay to ModernBERT encoder layers.
`--optimizer-policy legacy` retains the earlier single-rate/single-decay
behavior for controlled comparisons. This implementation keeps PyTorch AdamW;
grouping alone is not evidence of better generalization.

Both `--lr-scheduler linear` and `cosine` support warmup, counted in optimizer
updates. `--gradient-accumulation-steps` normalizes gradients by the actual
weight sum across the update, including uneven tail microbatches; the scheduler
advances only after optimizer updates. Adam betas/epsilon and
`--max-grad-norm` are explicit. Nonfinite gradient norms fail the run. Tuning
summaries record parameter groups, planned/completed updates, first/peak/last
rates, loss/rate traces, raw gradient norms and clipping frequency.

`--focal-gamma 2` is an optional training-only hard-label objective:
`(1 - p_gold)^gamma * CE`, including the derivative of the modulation factor.
The default `0` preserves existing CE exactly. Focal loss is incompatible with
label smoothing here; invalid exponents fail before model loading. Correct-teacher
distillation gates, per-row source weights and KD coefficients stay unchanged.
The same objective is used by minibatch training and full-gradient/stochastic
audits, and its exponent is recorded in checkpoint-resume contracts and reports.
It changes no inference threshold, model size or Swift action rule. Published
[focal calibration results](https://proceedings.neurips.cc/paper/2020/hash/aeb7b30ef1d024a76f21a1d40e30c302-Abstract.html)
motivate the experiment; local safety/recall gates still decide whether it helps.

Optional `--validation-max-benign-junk N --validation-min-spam-recall R`
requires an explicit development set and early stopping. Only epochs satisfying
both action gates can become the development-selected checkpoint. Higher macro
F1 cannot override a failed action gate. If none qualifies, the final weights
are saved only for research with `eligibleEpochFound: false`; they are not a
selected model. Patience starts after a qualifying epoch; the fixed epoch cap
still applies when no epoch qualifies. Old external suites remain later vetoes.
Direct export/install refuses a run with no qualifying epoch when early
stopping is enabled; use `--skip-export` to retain research-only weights.

Public review schema 3 (`profile: typed-locale-v1`) adds explicit reviewed
`numberRoles`/`timeRoles`, neutral period values and Vietnamese currency/name/
contact rendering. Missing roles fail rather than being guessed as OTPs.
Unrecoverable source anonymizers are excluded with reasons. Schema 1/2 rendering
is preserved; historical packages and scores are not silently rewritten.
`bridge_review_lineage.py` maps new materialized text hashes to their prior
rendering so contributor/family splits remain fixed across the repair.

Public review schema 4 (`profile: typed-locale-host-v2`) requires an explicit
`publicURLHosts` list matching the source. It preserves each reviewed public
host and HTTP/HTTPS shape while removing path/query identifiers. It never
substitutes another random shortener or treats a host as a runtime allowlist.
Unrecoverable, credentialed or identifier-bearing hosts fail admission.
Optional reviewed `moneyRoles` distinguish Vietnamese `credit_limit` from a
generic `amount`; number/time roles remain mandatory when placeholders exist.
Schemas 1–3 remain reproducible, including their historical rendering defects.
V27 audits the affected source cohort, preserves old gold/metrics, repairs46
training URLs using their own original sources, and evaluates a fixed-budget
continuation. See [the false-positive review](../../docs/engineering/signal-false-positive-v27-20261029.md).

`prepare_repaired_signal.py --out NEW_DIRECTORY` reproduces the October 28
hash-pinned repair plan in `Training/signal-corpus-repair-v5.json` (under
`tools/apple-trainer`). It rebuilds core synthetic seeds, caps source buckets,
omits derived copies, quarantines semantic conflicts and enforces development/
external-family isolation. Existing outputs are never overwritten. See
[the repair and three optimizer/LR comparisons](../../docs/engineering/signal-repair-optimizer-20261028.md)
for their measured limits; none is a release selection.

## Grouped development and bounded training

Use `prepare_grouped_development.py` before new experiments. A separately
reviewed lineage map groups public contributors, authored families and derived
parents; exact, digit-normalized, template and full-string family matches also
join groups. Previously trained or unknown-history rows stay training-only.
These string signatures do not prove semantic independence between paraphrases.
Start from a checkpoint that predates the newly reserved development material;
removing rows from a continuation corpus cannot undo earlier exposure.
`build_review_lineage.py` reconstructs the local lineage from checksum-verified
reviews and caches, using the same sanitization and deterministic fictional
values as the importer. Its default marks every source historical; explicitly
name `--unseen-source` only with initialization-checkpoint evidence. Conflicting
donor/exposure records for one materialized text fail closed.

```bash
python3 tools/transformer-trainer/prepare_grouped_development.py \
  --input build/signal-enrichment-v3-20261027/train-v4.ndjson \
  --lineage build/signal-generalization-20261027/review-lineage.json \
  --out build/signal-generalization-20261027/train.ndjson \
  --development-out build/signal-generalization-20261027/development.ndjson \
  --report build/signal-generalization-20261027/group-split.json
```

`train_mmbert.py --validation-input PATH --validation-fraction 0
--early-stopping-patience 2 --early-stopping-delta .002` checks train/development
signature isolation before training, evaluates development macro F1 each epoch,
and restores the selected epoch's trainable parameters. Dropout is re-enabled
after each development evaluation. The summary records the development hash,
epoch history and selection policy. It never needs a final test for early
stopping. Existing commands without early stopping retain final-epoch behavior.

Preregister a small candidate budget, source-weight cap and hyperparameters.
Select using grouped development, then apply external regression vetoes and
the production Swift artifact checks. Evaluate a freshly frozen final test only
after candidate selection, once; do not tune gold, thresholds or another
checkpoint against its errors. A repeatedly inspected holdout becomes a
development regression set. Always report raw labels separately from final
Swift actions, benign-to-junk and benign-to-promotion, and language/source
coverage. High aggregate accuracy alone can hide weak minority classes.

`signal_quality_gate.py` checks artifact-bound Swift reports against explicit
accuracy and benign-to-junk targets on disjoint datasets. Passing those targets
does not bypass per-suite raw-label or physical-device release gates. The
[October 27 generalization experiment](../../docs/engineering/signal-generalization-20261027.md)
records the reviewed additions, frozen split and bounded recipes.

`audit_generalization.py` compares frozen training/development predictions by
source, language and label, optionally with initialization predictions. It
reports reweighted source-matched gaps, missing source/label support, token
truncation, action versus leaf errors and narrow read-only taxonomy findings.
It does not fit a model, relabel data or read the final test. See the
[October 27 root-cause audit](../../docs/engineering/signal-generalization-root-cause-20261027.md)
for confirmed label conflicts, synthetic dominance and preprocessing defects.
The shared family signature now also normalizes bare SMS links; old corpus
hashes remain evidence of their historical bytes, not guarantees that an older
isolation implementation caught every dynamic URL template.

## Reviewed junk recall v9 research

The opt-in `Training/signal-recall-v9.json` corpus (under `tools/apple-trainer`)
adds 68 reviewed public training messages, reserves 40 new grouped development
messages, and keeps all prior protected signatures. `prepare_recall_signal.py`
rebuilds the fixed split from the local sanitized accepted pool and the v8r2
foundation; the checked-in corpus/manifest are sufficient to run training.
The raw review queues are discarded, with hash-only review decisions retained.

From the repository root, use a fresh output directory:

```bash
tools/transformer-trainer/.venv/bin/python tools/transformer-trainer/run_approved_signal.py \
  --profile tools/transformer-trainer/experiments/signal-recall-v9-b-spam-objective.json \
  --out build/NEW_RECALL_STUDY
```

`--spam-loss-weight` adds training-only junk-vs-rest BCE. Its positive weight
uses only training labels and is capped at three; no inference thresholds or
model ABI change. This option defaults to zero and is pinned in resume contracts.
The closed A/B study and one fixed-budget junk-row diagnostic are **not qualified
models** under the original strict protocol. A was subsequently selected as a
research baseline under the user's relaxed accuracy tradeoff; do not resweep
their development sets or treat that change as independent release validation.
See [all metrics and limits](../../docs/engineering/signal-recall-v9-20261028.md).

## Stage-relative replay ownership

The [v12 study](../../docs/engineering/signal-stage-replay-20261028.md) found1268
historical rows still receiving new-correction treatment after A had learned
them. New continuation profiles can declare `stageReplayAudit` with the frozen
checkpoint's `baselineCorpusManifest`. The runner audits novelty by text hash,
not broad provenance prefixes. Historical rows marked new, missing new-row
ownership, omitted/duplicated baseline rows and unreviewed relabeling fail before
training. `allowHistoricalControl` is only for explicit reproduction controls.

V12's stage-specific prefixes are `public-reviewed-v11:` and
`authored-reviewed-v12:`. A future checkpoint owns a different learned corpus;
derive that stage's partition again instead of copying these prefixes. This
study's two600-step models did not improve existing junk recall, and A stays
selected. The authored72 development set is now inspected, has only12 correlated
trilingual family units, and was already saturated for A's junk/actions. It is
not a fresh real-world final or evidence that more synthetic junk would help.

## Reviewed multilingual views and the MPS frozen boundary

The [v31 study](../../docs/engineering/signal-translation-v31-20261029.md)
compares uniform sampling, bounded language/action sampling, aligned translated
views, and paired consistency, using two fixed seeds. Its clean base has 3,497
rows; 152 translations belong to 58 existing training families. Translations are
views, not additional independently weighted roots or independent evaluation
examples. Every descendant stays on the training side. A pinned view spec
checks ownership, labels, protected signatures, reviews and 96-token evidence.

`--multilingual-view-spec` with `--multilingual-mode` enables this experimental
path. It requires correct-teacher gated KD and explicit development evaluation;
export/install and other auxiliary loss combinations are rejected. Both views
retain supervised labels. Only the `consistent` mode adds Jensen-Shannon loss.
The full-gradient probe integrates all accepted views with sampling weights.

Partial ModernBERT training on MPS automatically enables an input gradient at
the first trainable attention LayerNorm. This avoids a locally reproduced
PyTorch 2.5.1 backward error after mixed batch sizes. It adds no trainable model
parameters and does not unfreeze earlier layers. The hook is removed when
training returns, before prediction/export. The optimization summary records
`frozenBoundaryInputGradient`; tests compare mixed-batch CPU/MPS gradients.
The [v30 incident](../../docs/engineering/signal-translation-v30-20261029.md)
preserves the failed trajectory, cold replays, warm-batch reproducer and fix.
Do not use v30 to select a training method. Cold checkpoint replay alone did
not validate that training trajectory.

Use the pinned v31 profiles with `run_approved_signal.py` and a new output
directory. Keep the retained v21 model until independent release gates pass.
Old regression scores and translated training views are not a fresh final set.
