#!/usr/bin/env python3
"""Export unpublished precision candidates from a mapped W4A32 Signal model.

No training, installation, signing, or release selection occurs here. Re-run
the external holdouts, Swift action suite, and physical-device gates afterward.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import shutil

from externalize_embeddings import EMBEDDING_PATH, MODEL_ABI, directory_sha256, sha256

PROFILES = ("linear16", "mixed16", "finite16", "finite16norm32")
FINITE_MASK = -10_000.0


def replace_attention_sentinel(program) -> None:
    """Replace only the shared mask-select sentinel, never arbitrary weights.

    FP32's minimum becomes -inf in FP16. Fully masked padding-query rows then
    make softmax non-finite. A finite negative sentinel avoids that overflow;
    this is a numerical graph change and still needs full quality validation.
    """
    import numpy as np
    from coremltools.converters.mil.mil import Builder as mb

    main = program.functions["main"]
    matches = [op for op in main.operations if op.op_type == "const"
               and isinstance(op.outputs[0].val, np.floating)
               and op.outputs[0].val == np.finfo(np.float32).min]
    if len(matches) != 1:
        raise ValueError("expected exactly one FP32 attention-mask sentinel")
    op = matches[0]
    value = op.outputs[0]
    consumers = list(value.child_ops)
    if not consumers or any(child.op_type != "select" or child.a is not value
                            for child in consumers):
        raise ValueError("sentinel has uses outside mask selection")
    with main:
        replacement = mb.const(val=np.float32(FINITE_MASK),
                               name="finite_attention_mask", before_op=op)
    main.replace_uses_of_var_after_op(op, value, replacement)
    main.remove_ops([op])


def export(source: Path, output: Path, profile: str) -> dict:
    if profile not in PROFILES:
        raise ValueError("unknown precision profile")
    if output.exists():
        raise ValueError("output already exists; use a new candidate directory")
    manifest = json.loads((source / "SiftSignalModel.manifest.json").read_text())
    package = source / manifest["modelArtifact"]
    tokenizer = source / manifest["tokenizerArtifact"]
    if (manifest["modelABI"] != MODEL_ABI
            or manifest["runtimeProfile"].get("computePrecision") != "float32"
            or manifest["quantizationProfile"]["weightBits"] != 4
            or not (package / EMBEDDING_PATH).is_file()):
        raise ValueError("requires a mapped W4A32 source")
    if (directory_sha256(package) != manifest["sha256"]
            or sha256(tokenizer) != manifest["tokenizerSHA256"]):
        raise ValueError("source checksum mismatch")

    import coremltools as ct
    from coremltools.converters.mil.frontend.milproto.load import load

    model = ct.models.MLModel(str(package), skip_model_load=True)
    spec = model.get_spec()
    program = load(spec, spec.specificationVersion, model.weights_dir)
    if profile.startswith("finite16"):
        replace_attention_sentinel(program)

    def select(op):
        if profile == "linear16":
            return op.op_type == "linear"
        if profile == "finite16":
            return True
        if profile == "finite16norm32":
            return op.op_type not in ("layer_norm", "softmax")
        length = manifest["maxSequenceLength"]
        return (op.op_type not in ("layer_norm", "softmax", "matmul")
                and not any(len(v.shape) >= 3 and tuple(v.shape[-2:]) == (length, length)
                            for v in op.outputs if hasattr(v, "shape")))

    converted = ct.convert(
        program, source="milinternal", convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.transform.FP16ComputePrecision(op_selector=select),
        skip_model_load=True,
    )
    output.mkdir(parents=True)
    target = output / manifest["modelArtifact"]
    converted.save(str(target))
    shutil.copy2(package / EMBEDDING_PATH, target / EMBEDDING_PATH)
    shutil.copy2(tokenizer, output / manifest["tokenizerArtifact"])
    candidate = copy.deepcopy(manifest)
    for key in ("signature", "keyID", "remoteBaseURL"):
        candidate.pop(key, None)
    candidate.update(version=manifest["version"] + "-" + profile,
                     sha256=directory_sha256(target), releaseEligible=False)
    candidate["validationMetrics"] = {
        "fixedAccuracy": 0, "promotionAccuracy": 0, "fp16Agreement": 0,
        "languageAccuracy": {"zh": 0, "en": 0, "ja": 0},
    }
    candidate["runtimeProfile"]["computePrecision"] = (
        "float16" if profile == "finite16" else "mixedFloat16Float32")
    candidate["quantizationProfile"].update(identifier="w4-" + profile, activationBits=16)
    candidate["precisionTransform"] = {
        "sourceModelSHA256": manifest["sha256"], "profile": profile,
        "attentionMaskSentinel": FINITE_MASK if profile.startswith("finite16") else None,
    }
    candidate["remoteArtifacts"] = [
        {"path": p.relative_to(output).as_posix(), "sha256": sha256(p),
         "byteCount": p.stat().st_size}
        for p in sorted(output.rglob("*")) if p.is_file()
    ]
    candidate["downloadBytes"] = sum(a["byteCount"] for a in candidate["remoteArtifacts"])
    (output / "SiftSignalModel.manifest.json").write_text(json.dumps(candidate, indent=2) + "\n")
    return candidate


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", choices=PROFILES, required=True)
    args = parser.parse_args()
    result = export(args.source, args.output, args.profile)
    print(json.dumps({k: result[k] for k in ("sha256", "downloadBytes", "releaseEligible")}, indent=2))
