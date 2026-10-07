# Signal 12-layer NeuralNetwork release, 2026-10-07

The selected route preserves the r33 mmBERT 12-layer checkpoint, label order,
length-96 input and full vocabulary. It changes the Core ML encoder export from
MLProgram to FP32 NeuralNetwork and reads the W4/block16 token embeddings through
the existing mapped-embedding ABI. There is no new distillation or fine-tuning.
The historical 22-to-12 teacher/student provenance remains in the manifest.

## Artifact and app compatibility

| Field | Value |
| --- | --- |
| Version | `signal-v5-r33-nn12-mapped` |
| Release sequence | 6 |
| Model ABI | `sift-signal-mapped-embedding-v1` |
| Minimum app | Sift 1.5, build 32 |
| Package SHA-256 | `5e7db0cb2e17b210532d240ad4cd1d21926e1e740f396ec78e03fd17e8f61092` |
| Download bytes | 171,886,849 |
| Profile | `nn-fp32-mapped-w4-block16` |
| Execution | CPU only, FP32 |

`weightBits: 32` describes the encoder; the profile's mixed granularity explicitly
records the W4 embeddings. Build 31 and earlier reject this profile, so sequence 6
requires build 32 even though the marketing version remains 1.5. The v3 signed
catalog preserves sequences 4 and 5 for compatible older clients. The v2 channel
is unchanged. Signal stays an on-demand download and is not bundled in the app.

## Quality

Evaluation uses the existing fixed external suites. The audit of the current
19,254-row source found no exact or digit-normalized overlap with all 27 suites,
including fixed, promotion and billing. Its stricter template comparison found
44 matches, which were removed for the separate newly trained lite candidates.
That current file does not prove byte-for-byte identity with every historical
teacher/student training input. These are export regression results, not proof
that the historical teacher never saw related templates. No training, labels,
thresholds or routing rules changed for this export.

| External evidence | Result |
| --- | --- |
| All 27 suites, raw labels | 1,931 / 1,957 (98.6714%) |
| All 27 suites, production Swift actions | 1,956 / 1,957 (99.9489%) |
| Fixed raw labels | 484 / 487 (99.3840%) |
| Promotion raw labels | 150 / 150 |
| Billing and conversation raw labels | 30 / 30 each |
| Standard four suites, final actions | 100% each |
| Readable end-to-end cases | 17 / 17 |
| Benign or transaction messages sent to junk | 0 |
| Top-1 agreement with unquantized reference, standard suites | 99.8565% |

The one additional-suite action error is promotion classified as junk. Quality
reports retain every error; these finite sets do not establish universal accuracy.
The existing distillation gate compares the export to the hash-pinned FP32 r33
reference; its historical `teacher` field does not mean that another teacher was
trained for this export. Language aggregates include the conversation suite in
the candidate report, unlike the older reference aggregate.

## Real IdentityLookup stress

Device: iPhone 17 (`iPhone18,3`), iOS 27.0.1 (24A446). An isolated test extension
ran the production `MessageFilterEngine` with a bundled loader for the exact
package above. It used no debugger and recorded aggregate synthetic zh/en/ja
classification stages in OSLog. Real SMS in this test extension is always allowed;
this probe cannot prove Messages notification suppression.

The run completed on October 7, 22:43:49–22:58:02 (UTC+08), PID 54482.

| Metric | Result |
| --- | ---: |
| Fresh engine/model reloads in the same OS process | 30 |
| Continuous warm classifications | 10,000 |
| Failed queries or fallback classifications | 0 |
| Reload P95 / P99 / maximum | 279.77 / 382.94 / 382.94 ms |
| Warm P95 / P99 / maximum | 137.83 / 170.79 / 538.47 ms |
| Absolute process-lifetime footprint peak | 19,891,944 bytes (18.97 MiB) |
| Minimum observed footprint + available process memory | 25,149,440 bytes |
| Peak headroom against that observed budget | 5,257,496 bytes |
| Initial / final footprint | 4,114,152 / 19,105,512 bytes |
| After explicit model release | 5,097,072 bytes |

These are 30 model reloads, **not 30 OS process launches**. An earlier real incoming
SMS in the same artifact's test extension completed at 22:19:53 in 38.98 ms, with
a process-lifetime peak of 18,712,176 bytes. No matching memory-limit termination
was observed in these completed runs.

Initial-to-final growth is **14,991,360 bytes**. It must not be presented as passing
a 10% drift check measured from immediately after loading. The process plateaued
after early cache allocation. The new profile therefore also requires an absolute
peak at most 20 MiB, at least 4 MiB of observed headroom, and at most 10% maximum
growth across the fixed second half of the run (queries 5,000–10,000). This window
has 51 checkpoints: first 19,072,744, maximum 19,203,816, last 19,121,896 bytes;
maximum growth is 131,072 bytes (0.6872%). The source evidence preserves both
initial growth and the explicit steady-state window.

These are qualification limits for this release, not an Apple-guaranteed memory
budget. The user's original 16 MB target was explicitly relaxed after observing
successful incoming-SMS execution. No claim is made for other hardware/OS versions,
30 fresh extension processes, or operation under every memory-pressure state.

## Production installation

Development-signed Sift 1.5 (32) passed separate physical-device XCTest invocations
for candidate installation, final-path priming and runtime evaluation. The actual
App Group artifact identity matched the tested package. Priming took 177 ms;
host runtime P95/P99 was 14.13/14.67 ms over 1,000 predictions with zero failures.
The NeuralNetwork compute plan contains 641 layers, 561 with an assigned device,
all 561 assigned to CPU. Unassigned constant/elementwise/reduction layers do not
carry a fabricated cost or accelerator placement.

The app-host process peaked at 357,763,080 bytes including XCTest and the app,
16,679,032 bytes above its measured baseline. These host numbers are deliberately
separate from the real extension's absolute peak and are not evidence of its
memory budget. The built app and extension include the production Classic/PII
resources as applicable and contain no bundled Signal model.

The **production Sift filtering extension** then received an actual SMS at
23:37:20 (UTC+08), PID 54986. It reported `selected=transformer`, `path=signal`,
`action=transaction`, `fallback=none`, `error=none`, and submitted its response
after 268 ms. Cold Signal loading took 66 ms and the inference path 193 ms.
The process-lifetime peak was 18,499,208 bytes; footprint at response submission
was 6,325,992 bytes. The process remained alive in the subsequent device inventory.
This validates the real shared-container loader and production response path in
addition to the isolated stress probe. It does not test suppression of a spam
notification: the received message was a verification code.

The development installation had no available purchase entitlement, so the first
production SMS at 23:14 used Classic. The second test selected the installed Signal
artifact using the opt-in `testSetModelForManualSMSValidation` device setup with
`SIFT_DEVICE_MANUAL_SMS_VARIANT=transformer`. Normal tests skip this setup. It
changes the real shared selection intentionally, without changing StoreKit or
the production paywall. Keep the containing app closed for the coordinated SMS
check; an ordinary launch without entitlement can select Classic again. The same
setup accepts `classic` to restore the earlier selection.

## Reproduction and release guards

`export_neuralnetwork.py` exports an unselected candidate from the local checkpoint
and mapped source. It checks source/tokenizer hashes, embedding shape and layout,
label order and the 22-to-12 training recipe. A repeated export produced an equal
Core ML protobuf graph (deterministic graph SHA-256
`8b858c0157a1b8ed4b107e39fb29141a6eedd36bae4a928e0ea3fd9aff756b9a`), although
protobuf map serialization and package identifiers can change package bytes.
Only the exact device-tested package above is selected for release.

`qualify_identitylookup_probe.py` requires all 30 reload and 100 warm checkpoints,
the completion summary, and a paired actual SMS receipt/response. It retains
SHA-256 references to the input logs. `record_device_metrics.py` binds host and
extension evidence to the candidate artifact and matching device model. The
selector and publisher both require the new absolute-memory proof, even when
their historical `--skip-device-evidence` flag is supplied. No skip flag was used
for this release.

Detailed local evidence lives under `build/signal-release-20261007/`: the candidate,
quality reports, signed selection/gate, extension evidence, source log archive and
three device XCTest result bundles. Large artifacts and device logs are ignored
and must not enter git. Logs contain stage metrics, not real SMS bodies or senders.
The [aggregate evidence record](evidence/signal-nn12-release.json) retains the
artifact/report/log hashes and release metrics without any real message content.

## Publication and validation

The signed sequence-6 release is published at
`https://sift.alkinum.com/models/releases/signal-v5-r33-nn12-mapped/`.
Every public artifact was read back and checked against its full SHA-256 before
the v3 channel pointer changed. Slow single-connection reads were replaced with
eight concurrent byte-range reads; every response's range, length and ETag was
checked, and bytes were hashed in file order. The publisher's selection, quality,
device, signature and immutability gates remained in force.

The public manifest/catalog were then decoded and signature-checked with the
actual Swift client implementation. Builds 19, 30 and 31 select sequence 5;
build 32 selects sequence 6. Final checks passed: Swift build, 185 Swift tests,
CoreSmokeTests, 153 trainer Python tests without skips, physical-device build and
the installation/prime/runtime/manual-selection XCTest checks. Pushing `release`
requests the Xcode Cloud app build; model publication does not itself deliver an
App Store/TestFlight binary.
