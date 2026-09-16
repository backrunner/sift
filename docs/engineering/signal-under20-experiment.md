# Signal memory and startup experiment — 2026-09-05

Target: absolute process peak below **20,000,000 bytes**, with model cold path
(tokenizer initialization + model load + first inference) around **150 ms**.
This does not yet measure the complete OS-to-IdentityLookup response time.

## Status

**Not device-qualified or published.** Online sequence 4 remains unchanged.
The 12-layer mapped W4A32 iPhone reference measured 24,856,320 bytes kernel
lifetime peak and 203.12 ms cold path. It misses both targets. These are
standalone app measurements, not an actual SMS extension invocation.

The local mapped model selected during the earlier device test remains in the
phone's App Group. New precision candidates are separate test files under app
Documents; they have not been activated as the SMS filter model.

## Precision candidates

The qualified 12-layer weights were transformed without training or changing
the 256k-token vocabulary, 96-token input, mapped embeddings, or 53 labels.

| Profile | Download bytes | External labels changed / 697 |
| --- | ---: | ---: |
| Online W4A32 reference | 108,748,513 | 0 |
| Mapped embedding, FP16 scales / FP32 compute | 96,456,684 | 0 |
| Linear operations FP16 | 96,508,484 | 0 |
| Mixed precision, FP32 attention and normalization | 93,574,049 | 0 |
| Finite-mask FP16 | 93,528,149 | 0 |
| Finite-mask FP16, FP32 normalization and softmax | 93,568,323 | 0 |

FP32's minimum attention-mask constant overflows to negative infinity in FP16.
The finite-mask candidates replace only that shared select operand with
-10,000. A CPU-only Core ML regression test checks that completely masked
padding-query rows remain finite and valid rows exclude masked tokens.

The reproducible `finite16` export has package SHA-256
`3e24e8be6be88f6a8e5e2a640f679e98ecc13d6b3878dbb86ffeb1acfd55cf42`.
Core ML package UUIDs/serialization can vary on re-export; bind new evidence
to the new hash. All candidates remain unsigned and release-ineligible.

For this exact export, CPU-only raw classification is 483/487 on fixed,
150/150 promotion, 30/30 billing, and 30/30 conversation. Every label matches
the original. Maximum absolute probability change is 0.0242921, so this is
not probability-identical. The production Swift action suite passes fixed
485/487 (99.59%), all other sets 100%, 17/17 readable cases, zero
benign/transaction-to-junk actions, and 100% rule overrides.

## Performance evidence and limits

Three alternating fresh Mac Release processes, using the current runtime,
completed 20 warmups and 1,000 measured inferences per trial with zero errors.
The finite-mask candidate's kernel lifetime peaks were 23,528,120;
23,413,432; and 23,495,352 bytes. Cold paths were 86.60, 23.81, and 18.84 ms.
The mapped FP32 reference peaks were 29,704,888; 24,789,712; and 24,232,656
bytes, with cold paths 262.56, 41.73, and 32.26 ms. The first trial includes
different cache/system-pressure effects; do not use it alone as a speedup
claim. **Even the Mac candidate peaks remain above 20 MB.**

Fresh iPhone evidence is now available for the finite-mask candidate. After
the compiled artifact was prepared, two fresh processes recorded kernel
lifetime peaks of **10,716,856** and **10,847,928 bytes**, cold paths of **13.14**
and **14.48 ms**, and zero inference failures. A first run that included
system/cache setup reached 20,973,240 bytes and 204.03 ms; it is retained as a
separate cold-install observation. The reference mapped model's repeated runs
peaked at 11.75 MB and took 20.75--21.73 ms. These measurements are standalone
host launches and still do not prove the IdentityLookup extension path.
Reports use unique run IDs to prevent stale copies from being accepted. The
older `iphone-mapped-fixed-shape-benchmark.json` from the prior experiment is
a stale copy after a failed launch and must not be used. It has been renamed
with a `.stale` suffix.

Artifacts and raw reports are ignored under
`build/diagnostics/under20-20260905/`, including
`finite-repro-validation.json`, `finite-repro-swift-actions.json`, and
`{mapped,finite16}-mac-current-{0,1,2}.json`.

Next required evidence is a fresh physical-iPhone comparison and a real SMS
extension invocation. If the physical peak still exceeds the target, encoder
structure/graph loading must be reduced further; smaller download size and
FP16 alone have not demonstrated the requested absolute memory budget.
