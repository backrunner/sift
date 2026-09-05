#!/usr/bin/env python3
"""Build a local Signal candidate with mapped, row-wise INT4 token embeddings.

This transforms an already holdout-qualified W4 model without retraining or
changing token IDs. It never installs or publishes the candidate.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import struct


MODEL_ABI = "sift-signal-mapped-embedding-v1"
EMBEDDING_PATH = "Data/com.apple.CoreML/weights/token-embedding.siftemb"
EMBEDDING_INPUT = "input_embeddings"
HEADER_SIZE = 64
MAGIC = b"SIFTEMB1"


def write_embeddings(path: Path, quantized, scales, *, scale_bytes: int = 4) -> dict:
    import numpy as np

    quantized = np.asarray(quantized)
    scales = np.asarray(scales)
    if quantized.ndim != 2 or scales.ndim != 2 or quantized.shape[0] != scales.shape[0]:
        raise ValueError("embedding data/scales must have matching rows")
    rows, width = quantized.shape
    if scale_bytes not in (2, 4) or not rows or not width or width % 2 or not scales.shape[1]:
        raise ValueError("invalid embedding dimensions or scale precision")
    if (not np.issubdtype(quantized.dtype, np.integer) or width % scales.shape[1]
            or np.min(quantized) < -8 or np.max(quantized) > 7):
        raise ValueError("expected symmetric signed INT4 row blocks")
    if not np.isfinite(scales).all():
        raise ValueError("non-finite scales")
    block_size = width // scales.shape[1]
    row_stride = width // 2 + scales.shape[1] * scale_bytes
    header = struct.pack("<8s6I", MAGIC, 1, rows, width, block_size, scale_bytes, row_stride)
    scale_dtype = "<f2" if scale_bytes == 2 else "<f4"
    converted_scales = scales.astype(scale_dtype)
    if not np.isfinite(converted_scales).all() or np.any((scales != 0) & (converted_scales == 0)):
        raise ValueError("scale conversion overflows or underflows")
    with path.open("wb") as handle:
        handle.write(header + bytes(HEADER_SIZE - len(header)))
        for start in range(0, rows, 1024):
            q = quantized[start:start + 1024].astype(np.int8).view(np.uint8) & 15
            packed = q[:, ::2] | (q[:, 1::2] << 4)
            scale_data = converted_scales[start:start + 1024].view(np.uint8)
            handle.write(np.concatenate([packed, scale_data], axis=1).tobytes())
    return {"rows": rows, "width": width, "blockSize": block_size,
            "scaleBytes": scale_bytes, "rowStride": row_stride, "byteCount": path.stat().st_size}


def read_embedding_rows(path: Path, ids):
    import numpy as np

    with path.open("rb") as handle:
        header = handle.read(HEADER_SIZE)
    if len(header) != HEADER_SIZE:
        raise ValueError("truncated embedding header")
    magic, version, rows, width, block, scale_bytes, stride = struct.unpack("<8s6I", header[:32])
    if (magic != MAGIC or version != 1 or scale_bytes not in (2, 4)
            or not 0 < rows <= 1_000_000 or not 2 <= width <= 4096
            or not block or width % 2 or width % block or any(header[32:])
            or stride != width // 2 + width // block * scale_bytes
            or path.stat().st_size != HEADER_SIZE + rows * stride):
        raise ValueError("invalid embedding file")
    ids = np.asarray(ids)
    if not np.issubdtype(ids.dtype, np.integer) or np.any(ids < 0) or np.any(ids >= rows):
        raise ValueError("token ID outside embedding vocabulary")
    mapped = np.memmap(path, mode="r", dtype=np.uint8, offset=HEADER_SIZE, shape=(rows, stride))
    selected = np.asarray(mapped[ids.reshape(-1)])
    packed = selected[:, :width // 2]
    q = np.empty((ids.size, width), dtype=np.int8)
    q[:, ::2] = packed & 15
    q[:, 1::2] = packed >> 4
    q[q >= 8] -= 16
    scales = selected[:, width // 2:].copy().view("<f2" if scale_bytes == 2 else "<f4").astype(np.float32)
    if not np.isfinite(scales).all():
        raise ValueError("non-finite scales")
    result = q.astype(np.float32) * np.repeat(scales, block, axis=1)
    return result.reshape((*ids.shape, width))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def directory_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    for file in sorted(p for p in path.rglob("*") if p.is_file()):
        digest.update(file.relative_to(path).as_posix().encode())
        with file.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    return digest.hexdigest()


def export(source: Path, output: Path, scale_bytes: int, minimum_build: int) -> dict:
    import coremltools as ct
    from coremltools.converters.mil.frontend.milproto.load import load

    if output.exists():
        raise ValueError("output already exists; use a new candidate directory")
    manifest = json.loads((source / "SiftSignalModel.manifest.json").read_text())
    source_model = source / manifest["modelArtifact"]
    if directory_sha256(source_model) != manifest["sha256"]:
        raise ValueError("source model checksum mismatch")
    tokenizer = source / manifest["tokenizerArtifact"]
    if sha256(tokenizer) != manifest["tokenizerSHA256"]:
        raise ValueError("source tokenizer checksum mismatch")
    if manifest["runtimeProfile"].get("computePrecision") != "float32":
        raise ValueError("this transform requires the qualified FP32-compute model")
    model = ct.models.MLModel(str(source_model), skip_model_load=True)
    spec = model.get_spec()
    program = load(spec, spec.specificationVersion, model.weights_dir)
    embedding_ops = [op for op in program.functions["main"].operations
                     if op.op_type == "constexpr_blockwise_shift_scale" and "tok_embeddings" in op.name]
    if len(embedding_ops) != 1:
        raise ValueError("expected exactly one blockwise-quantized token embedding")
    op = embedding_ops[0]
    if op.offset is not None:
        raise ValueError("non-symmetric embedding offsets are unsupported")
    quantized, scales = op.data.val, op.scale.val
    function = spec.mlProgram.functions["main"]
    block = function.block_specializations[function.opset]
    gather_ops = [item for item in block.operations if item.type == "gather"
                  and any(arg.name == op.name for arg in item.inputs["x"].arguments)]
    if len(gather_ops) != 1:
        raise ValueError("expected one embedding gather")
    gather = gather_ops[0]
    gathered_name = gather.outputs[0].name
    new_input = function.inputs.add()
    new_input.CopyFrom(gather.outputs[0])
    new_input.name = EMBEDDING_INPUT
    for item in block.operations:
        for arguments in item.inputs.values():
            for argument in arguments.arguments:
                if argument.name == gathered_name:
                    argument.name = EMBEDDING_INPUT
    block.operations.remove(gather)
    # Dead-code elimination removes the giant constexpr and index sanitation
    # branch. Re-emitting MIL compacts weight.bin to retain only live constants.
    program = load(spec, spec.specificationVersion, model.weights_dir)
    # The MIL round-trip can place identity outputs after classify, which the
    # serializer cannot handle for its literal string list. Export probabilities
    # directly; the runtime already maps this tensor using manifest label order.
    main = program.functions["main"]
    classifiers = [item for item in main.operations if item.op_type == "classify"]
    if len(classifiers) != 1 or list(classifiers[0].classes.val) != manifest["labels"]:
        raise ValueError("classifier label order does not match manifest")
    main.set_outputs([classifiers[0].probabilities])
    converted = ct.convert(
        program, source="milinternal", convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32, skip_model_load=True,
    )
    converted_spec = converted.get_spec()
    converted_spec.description.metadata.CopyFrom(spec.description.metadata)
    output.mkdir(parents=True)
    package = output / manifest["modelArtifact"]
    ct.models.MLModel(converted_spec, weights_dir=converted.weights_dir, skip_model_load=True).save(str(package))
    embedding_info = write_embeddings(package / EMBEDDING_PATH, quantized, scales, scale_bytes=scale_bytes)
    shutil.copy2(tokenizer, output / manifest["tokenizerArtifact"])
    candidate = copy.deepcopy(manifest)
    for key in ["signature", "keyID", "remoteBaseURL"]:
        candidate.pop(key, None)
    candidate.update({
        "modelABI": MODEL_ABI, "releaseSequence": manifest["releaseSequence"] + 1,
        "minimumAppBuild": minimum_build, "releaseEligible": False,
        "version": manifest["version"] + f"-mapped-embedding-s{scale_bytes * 8}",
        "sha256": directory_sha256(package),
        # The source's holdout scores do not certify a transformed candidate.
        "validationMetrics": {"fixedAccuracy": 0, "promotionAccuracy": 0, "fp16Agreement": 0,
                              "languageAccuracy": {"zh": 0, "en": 0, "ja": 0}},
        "embeddingTransform": {**embedding_info, "sourceModelSHA256": manifest["sha256"],
                               "input": EMBEDDING_INPUT, "path": EMBEDDING_PATH},
    })
    # Historical source directories predate the signed metadata-v2 fix. Match
    # actual FP32 compute rather than carrying the old A16 profile name forward.
    candidate["quantizationProfile"].update({"identifier": "w4a32-block16-ptq", "activationBits": 32})
    artifacts = [{"path": p.relative_to(output).as_posix(), "sha256": sha256(p), "byteCount": p.stat().st_size}
                 for p in sorted(output.rglob("*")) if p.is_file()]
    candidate["remoteArtifacts"] = artifacts
    candidate["downloadBytes"] = sum(a["byteCount"] for a in artifacts)
    (output / "SiftSignalModel.manifest.json").write_text(json.dumps(candidate, indent=2) + "\n")
    report = {"sourceDownloadBytes": manifest["downloadBytes"], "candidateDownloadBytes": candidate["downloadBytes"],
              "coreMLWeightBytes": (package / "Data/com.apple.CoreML/weights/weight.bin").stat().st_size,
              "embedding": embedding_info, "candidateSHA256": candidate["sha256"], "releaseEligible": False}
    (output / "embedding-export-report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scale-bytes", type=int, choices=[2, 4], default=4)
    parser.add_argument("--minimum-app-build", type=int, default=22)
    args = parser.parse_args()
    print(json.dumps(export(args.source, args.output, args.scale_bytes, args.minimum_app_build), indent=2))


if __name__ == "__main__":
    main()
