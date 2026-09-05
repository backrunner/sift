# Message-filter memory and diagnostics

## Device evidence, 2026-09-05

The iPhone 17 running iOS 27.0 build 24A5424a recorded four
`MessageFilterExtension` process terminations in three Jetsam reports on
2026-09-03 (09:30:14, 13:18:32, 17:45:02, UTC+08:00). Each process entry has
`reason: per-process-limit`, `rpages: 1536`, and a 16384-byte page size:
24 MiB. The corresponding extension is TestFlight Sift 1.4 build 21.
The two processes in the 13:18 report need not have died at exactly the same
time; this is the report timestamp.

Apple's [Jetsam report documentation](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports)
defines `per-process-limit` as crossing the system's resident-memory limit
and explains the `rpages × pageSize` calculation. Its
[App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)
says extensions have significantly lower limits than foreground apps and
that different extension types can have different limits. The reviewed
[IdentityLookup extension documentation](https://developer.apple.com/documentation/identitylookup/ilmessagefilterextension)
does not specify a fixed numeric memory limit. Treat 24 MiB as observed
evidence on this device/OS, not an API guarantee across devices.

The public `os_proc_available_memory()` API (iOS 13+) returns bytes remaining
before the current process hits its current dirty-memory limit. The SDK's
`os/proc.h` explicitly states that limits can change, the value must not be
cached, and other threads/frameworks can invalidate it immediately. Zero can
mean either no applicable app limit or that the limit has been exceeded.
It is not device-wide free RAM and is not a reservation for the next model
allocation. No fixed threshold is used here to claim that Signal is safe.

## Why distillation did not prove extension safety

The selected W4A32 block16 model is a 12-layer student of a 22-layer teacher,
with a 384-wide hidden state, 256000-token vocabulary and length-96 input.
Its checkpoint contains 121484981 parameters, including 98304000 token
embedding parameters (80.9%). Transformer layers account for 23011968
parameters. Halving the layer count again would remove only about 9.5% of
total parameters at the same width/vocabulary.

The download comprises about 91.22 MB of weights, 17.37 MB of compact tokenizer,
and model metadata: 108748513 bytes overall. These are decimal file sizes,
not resident/dirty process memory. The tokenizer is already memory-mapped.
W4 compresses stored weights; the runtime uses FP32 compute. Model
specialization, decompression, activations, prediction scratch buffers,
framework overhead and overlapping requests can still create a peak above
an extension limit. The existing stack samples pass through Core ML,
Espresso and BNNS, but do not establish which allocation caused the peak.

Existing `TransformerDeviceTests` run in the containing app and call the engine
directly. They measure useful model latency, accuracy and memory behavior,
but do not execute under IdentityLookup's extension limits. The old
30-cold/10000-warm counters were also written into the production shared
preferences; device benchmarks now use an isolated, cleaned UUID suite.

## Added runtime evidence

Each real filter request gets a random request UUID. The extension writes
`message_filter_stage` JSONL and OSLog records before and after tokenizer
loading, model initialization, tokenization, mapped embedding lookup, prediction and response delivery,
as well as Classic fallback and watchdog response stages. The records contain
the local PID, bundle/build, requested artifact, elapsed milliseconds,
current physical footprint, process-lifetime footprint peak, and available
process memory. A cache hit does not repeat model-load stages.

Stage records are enabled without developer mode and contain no SMS text,
sender, phone number, or persistent device/account identifier. Completion
records carry the request UUID/PID; category/confidence/routing details remain
under the existing developer-mode setting. The existing log export includes
the new records. JSONL remains bounded by the existing rotation policy.
Failed file writes are reported to OSLog.

Persisting before expensive operations leaves useful breadcrumbs when a
process never reaches completion. It cannot log *after* a Jetsam kill. The
process-lifetime peak is not a per-request peak, and a missing completion can
also reflect log rotation, truncation, or collection while work is active.
Use a matching system report to establish the termination reason. A recorded
response submission does not prove the Messages app suppressed notification.

Analyze exported logs and system reports locally:

```bash
python3 tools/transformer-trainer/analyze_filter_diagnostics.py \
  --logs /path/to/Sift-Diagnostics.jsonl \
  --jetsam /path/to/JetsamEvent.ips \
  --output /path/to/filter-summary.json
```

The analyzer separates interleaved request IDs, reports watchdog completions,
retains requests with no observed completion, tolerates a truncated final
JSONL record, and extracts only the relevant extension entries from Jetsam.
It does not join reports based on PID alone, because PIDs can be reused.

## Runtime changes and remaining optimization work

- Core ML/tokenizer initialization and predictions now have explicit
  autorelease pools, so temporary Objective-C objects are drained between
  loading and inference and between successive predictions.
- Predictions on one cached `TransformerTextClassifier` are serialized to
  avoid overlapping Core ML workspaces. This does not serialize all extension
  processes or make a single oversized inference safe.
- Stage logging itself drains temporary objects before the next model phase.
- Artifact regression tests now honor the manifest's compute-unit policy.

These changes reduce avoidable object lifetime and concurrency. They do not
constitute a measured solution to the 24 MiB termination. The published
sequence-4 model is unchanged; a separate experimental candidate is described
below.
An in-process timeout/Classic fallback cannot recover after the OS kills the
entire process.

Existing candidates from the same student checkpoint illustrate the size and
quality tradeoff (historical external holdout results, not a new selection):

| FP32 compute candidate | Download bytes | Fixed 487 | Promotion 150 |
| --- | ---: | ---: | ---: |
| W4 block16, selected | 108748513 | 99.18% | 100% |
| W4 block32 | 93564129 | 98.36% | 100% |
| W8 per-channel | 140309621 | 99.59% | 100% |

Historical directory/profile names say `w4a16` even for the FP32 export;
check `runtimeProfile.computePrecision`, not that old filename.
The smaller block32 candidate regresses fixed-set accuracy and should not
replace the current model on size alone.

Prioritize experiments in this order:

1. Capture real extension cold-load/prediction phases on affected OS builds,
   with debugger detached. Find whether tokenizer, Core ML specialization,
   first prediction, or subsequent prediction causes the peak. Include bursts
   and cold starts after an OS update; app-side priming is not proof of reuse
   by the extension.
2. Evaluate FP16 compute, shorter input buckets, and alternate Core ML
   specialization strategies independently. FP16 and shorter inputs may
   reduce buffers but can change accuracy/backend behavior. Core ML compressed
   file size is not a promise of compressed resident execution.
3. Address the embedding matrix: evaluate the mapped candidate below, or
   distill a smaller-width student with a smaller multilingual vocabulary.
   Do not prune vocabulary just from
   a narrow Chinese corpus; zh/en/ja and unknown-token/byte fallback coverage
   remain first-class requirements.
4. Compare candidates only after removing exact and digit-normalized overlap
   against fixed, promotion, billing/card and conversation holdouts. Validate
   labels and final actions on all holdouts plus real extension memory and
   system termination evidence. Aim for measured headroom below the observed
   limit, not operation exactly at it.

The current release-evidence exporter still accepts engine benchmark
snapshots; its success alone must not be treated as an IdentityLookup memory
certification. Actual incoming-message evidence remains required.

## Validation of the runtime changes

On 2026-09-05, Swift build, all 236 Swift tests and CoreSmokeTests passed.
The iOS app and extension compiled for a generic physical iOS destination
with code signing disabled. All 134 transformer tooling tests passed, and
the multilingual privacy pages built successfully with Vite. The log analyzer
recovered the four extension terminations from the three collected reports.

The existing sequence-4 artifact was evaluated through the updated CPU-only
runtime on all 697 fixed, promotion, billing/card and conversation holdout
rows. Final routing accuracy matched its prior action report: 99.59% fixed,
100% promotion, 100% billing/card and 100% conversation; no additional benign
messages were routed to junk. These are action metrics, not raw label accuracy.
The runtime changes have not yet been installed and exercised with real
incoming SMS, so no lower extension peak is claimed.

The build also exposed a pre-existing invalid Info.plist integer containing
an unexpanded build variable. It now uses a string build setting and parses
either string or numeric values; the built minimum release sequence remains 4.

## Mapped embedding candidate, 2026-09-05

`tools/transformer-trainer/externalize_embeddings.py` now transforms the
qualified W4 block16 FP32-compute artifact without retraining or changing
token IDs, the vocabulary, sequence length, teacher/student provenance,
encoder weights, or label order. It replaces the embedding constexpr/gather
with a `[1, 96, 384]` FP32 `input_embeddings` input. The Core ML package's live
weight file shrinks from 91219584 to 17491456 bytes. This is a file-size
measurement; the original Core ML backend may fuse or lazily materialize
constexpr/gather, so removing it does not establish a corresponding reduction
in resident memory.

`MappedTokenEmbedding` uses a read-only private `mmap`, validates the header
and exact file length, and expands only the requested INT4 rows directly into
the Core ML input tensor. That tensor is 147456 bytes (144 KiB); there is no
whole-vocabulary FP32 Swift array. Invalid IDs and non-finite scales fail into
the existing inference fallback. Mappings survive atomic model replacement;
installed artifacts must never be truncated in place.

The binary format is a 64-byte header (`SIFTEMB1`, little-endian version, row
count, width, block size, scale-byte count, row stride, then zero-reserved
bytes), followed by rows of low-nibble-first signed INT4 values and block
scales. Two candidates retain the same INT4 values:

| Candidate | Scale storage | Embedding bytes | Total download bytes |
| --- | --- | ---: | ---: |
| Existing sequence 4 | FP32, within Core ML | included in weight file | 108748513 |
| Mapped equivalent | FP32 | 73728064 | 108744684 |
| Mapped smaller | FP16, expanded to FP32 for multiplication | 61440064 | 96456684 |

The smaller candidate saves 12291829 bytes (11.30%). This is FP16 **scale
storage**, not FP16 model compute; all encoder compute remains FP32 CPU-only.
The old historical `w4a16` metadata is normalized to the existing signed
`w4a32-block16-ptq` contract when creating candidates.

The sidecar lives at
`SiftSignalModel.mlpackage/Data/com.apple.CoreML/weights/token-embedding.siftemb`.
It is covered both by the model directory SHA-256 (and thus cache identity)
and by the remote artifact entry. Loader, installation smoke test, priming,
artifact runner and device benchmark retain the original package URL for
this file even when inference loads the compiled `.mlmodelc`. Missing sidecars
reject discovery. The new ABI is `sift-signal-mapped-embedding-v1`, requiring
at least app build 22 and release sequence 5. These are experimental candidate
manifests, unsigned and `releaseEligible: false`, with release validation
metrics unset. The release catalog and production resource list were not
changed.

### External quality validation

`validate_mapped_embeddings.py` compares raw labels and every probability on
all four existing leak-free external holdouts using the local checkpoint
tokenizer and CPU-only Core ML. Both candidate tokenizers have the original
SHA-256. No training or internal-validation-based selection is involved.

| Holdout | Rows | Original correct labels | Changed labels, FP32 scales | Changed labels, FP16 scales |
| --- | ---: | ---: | ---: | ---: |
| Fixed | 487 | 483 (99.18%) | 0 | 0 |
| Promotion | 150 | 150 | 0 | 0 |
| Billing/card | 30 | 30 | 0 | 0 |
| Conversation | 30 | 30 | 0 | 0 |

The FP32-scale version is probability-identical on all 697 rows. The FP16-scale
version's maximum absolute probability difference is 0.000318826, with no
changed labels. Both also passed the Swift tokenizer/classifier/engine action
regression: fixed 99.59%, promotion/billing/conversation 100%, benign-to-junk
zero, and rule overrides 100%. This does not prove equivalence for every
possible message.

Reproduce the candidate and raw quality report with the trainer venv:

```bash
tools/transformer-trainer/.venv/bin/python tools/transformer-trainer/externalize_embeddings.py \
  --source /path/to/qualified-w4-directory \
  --output build/mapped-candidate --scale-bytes 2
tools/transformer-trainer/.venv/bin/python tools/transformer-trainer/validate_mapped_embeddings.py \
  --source /path/to/qualified-w4-directory \
  --candidate build/mapped-candidate \
  --checkpoint /path/to/student-checkpoint \
  --output build/mapped-candidate/raw-holdouts.json
```

### Memory evidence and deployment status

All candidate artifacts and detailed reports are ignored under
`build/diagnostics/mapped-embedding-20260905/`. The runtime benchmark now also
records the kernel process-lifetime physical-footprint peak before compute
plan inspection. Sampling only after predictions missed transient peaks.

The macOS comparison uses CPU-only Release builds, already compiled packages,
three alternating fresh processes per model, 20 warmups and 1000 timed
predictions per process. OS filesystem and Core ML specialization caches are
not cleared. Desktop measurements do not establish iOS extension safety.

| Median, macOS Release | Original | Mapped FP16 scales |
| --- | ---: | ---: |
| Model load, existing specialization cache | 5.85 ms | 5.58 ms |
| First prediction | 11.48 ms | 11.53 ms |
| Warm prediction P95 | 9.42 ms | 7.47 ms |
| Final physical footprint | 21.72 MiB | 21.58 MiB |
| Kernel lifetime footprint peak | 23.28 MiB | 23.14 MiB |

Warm P95 improved by about 20.7% in this desktop run, but the memory reduction
was only about 0.14 MiB. Earlier first-process measurements with unprimed
path-specific specialization reached 28.63/28.39 MiB respectively. Those
first runs also overlapped unrelated build work and are not controlled latency
comparisons. The small memory difference does **not** establish adequate
headroom under the observed 24 MiB iPhone extension limit. The candidate is
useful for download size and this measured warm latency; it is not yet a
solution to the confirmed Jetsam failures.

An isolated iPhone probe project was prepared under `device-probe/`, but its
build could not obtain a development provisioning profile for
`com.alkinum.sift.memoryprobe`: Xcode reported `No Accounts` and `No profiles`.
No probe or replacement Sift app was installed, and the TestFlight app and its
downloaded model were not changed. Actual incoming SMS with the debugger
detached, including cold starts and bursts, remains the required memory gate.

The final code passed Swift build, all 242 Swift tests, CoreSmokeTests, a generic
iOS app/extension build, and all 138 trainer Python tests in the trainer venv.
The decoder tests cover signed nibble order, FP16/FP32 scales, repeated rows,
unaligned row data, invalid/truncated headers, out-of-range IDs, non-finite
scales, mapping lifetime after unlink, and embedding inclusion in model
identity/discovery. The system Python run passed with four NumPy-dependent
tests skipped; the trainer venv ran those four successfully.
