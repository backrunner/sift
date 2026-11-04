#!/usr/bin/env python3
"""Export an unselected CPU NeuralNetwork encoder with mapped INT4 embeddings.

Preserves the checkpoint's 12 encoder layers and FP32 weights. This performs no
training, selection, installation, or publication. Qualify the resulting bytes
on holdouts and inside IdentityLookup before making a signed release.
"""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import shutil
import struct
import tempfile

from externalize_embeddings import EMBEDDING_PATH, MODEL_ABI, directory_sha256, sha256, write_embeddings
from check_distillation_gate import validate_distillation_provenance


def quantize_checkpoint_embeddings(weights, block_size: int = 16):
    """Symmetric signed INT4, per row/block; zero blocks stay exactly zero."""
    import numpy as np

    weights = np.asarray(weights, dtype=np.float32)
    if weights.ndim != 2 or block_size < 1 or weights.shape[1] % block_size:
        raise ValueError("invalid checkpoint embedding shape or block size")
    if not weights.size or not np.isfinite(weights).all():
        raise ValueError("checkpoint embeddings must be nonempty and finite")
    rows, width = weights.shape
    quantized = np.empty((rows, width), dtype=np.int8)
    scales = np.empty((rows, width // block_size), dtype=np.float32)
    for start in range(0, rows, 1024):
        blocks = weights[start:start + 1024].reshape(-1, width // block_size, block_size)
        scale = np.max(np.abs(blocks), axis=-1) / 7
        divisor = np.where(scale > 0, scale, 1)
        quantized[start:start + 1024] = np.clip(
            np.rint(blocks / divisor[..., None]), -7, 7
        ).astype(np.int8).reshape(-1, width)
        scales[start:start + 1024] = scale
    return quantized, scales


def unsigned_candidate_manifest(manifest: dict) -> dict:
    candidate = copy.deepcopy(manifest)
    for key in ("signature", "keyID", "remoteBaseURL", "deviceMetrics", "selection",
                "validationAccuracy", "testAccuracy", "validationReport"):
        candidate.pop(key, None)
    candidate["releaseEligible"] = False
    candidate["validationMetrics"] = {"fixedAccuracy": 0, "promotionAccuracy": 0,
                                      "fp16Agreement": 0, "languageAccuracy": {}}
    return candidate


def export(checkpoint: Path, source: Path, output: Path, version: str, sequence: int,
           training_summary: Path | None = None) -> dict:
    import coremltools as ct
    import numpy as np
    import torch
    from transformers import AutoModelForSequenceClassification
    from train_mmbert import patch_modernbert_for_coreml_export

    if output.exists():
        raise ValueError("output already exists; use a new candidate directory")
    if training_summary is None and (checkpoint.parent / "tuning-summary.json").exists():
        raise ValueError("a tuned checkpoint requires --training-summary to rebuild its embeddings")
    manifest = json.loads((source / "SiftSignalModel.manifest.json").read_text())
    valid, reason = validate_distillation_provenance(manifest)
    provenance = manifest.get("distillation", {})
    if (not valid or provenance.get("teacherLayers") != 22 or provenance.get("studentLayers") != 12
            or provenance.get("temperature") != 2 or provenance.get("distillAlpha") != 0.7):
        raise ValueError(f"source is not the qualified 22-to-12 layer recipe: {reason}")
    package = source / manifest["modelArtifact"]
    tokenizer = source / manifest["tokenizerArtifact"]
    if manifest["modelABI"] != MODEL_ABI or directory_sha256(package) != manifest["sha256"]:
        raise ValueError("mapped source ABI or package checksum mismatch")
    if sha256(tokenizer) != manifest["tokenizerSHA256"]:
        raise ValueError("tokenizer checksum mismatch")
    if sequence < 6 or sequence < manifest["releaseSequence"]:
        raise ValueError("release sequence must be at least 6 and not precede the source")
    summary = json.loads(training_summary.read_text()) if training_summary else None
    if summary is not None and not summary.get("replayPreservation"):
        raise ValueError("fine-tuned export requires replay-preservation training provenance")
    from compact_tokenizer import write_compact_bpe_tokenizer
    with tempfile.TemporaryDirectory() as temporary_directory:
        regenerated = write_compact_bpe_tokenizer(
            checkpoint / "tokenizer.json", Path(temporary_directory) / "tokenizer.siftbpe"
        )
        if sha256(regenerated) != manifest["tokenizerSHA256"]:
            raise ValueError("checkpoint tokenizer differs from the mapped source")
    model = AutoModelForSequenceClassification.from_pretrained(
        checkpoint, local_files_only=True, attn_implementation="eager"
    ).float().eval()
    if model.config.model_type != "modernbert" or model.config.num_hidden_layers != 12:
        raise ValueError("this release profile requires the qualified 12-layer mmBERT checkpoint")
    embedding = package / EMBEDDING_PATH
    with embedding.open("rb") as stream:
        magic, abi, rows, width, block, scale_bytes, stride = struct.unpack("<8s6I", stream.read(32))
    if (magic != b"SIFTEMB1" or abi != 1 or block != 16 or scale_bytes not in (2, 4)
            or rows != model.config.vocab_size or width != model.config.hidden_size
            or stride != width // 2 + width // block * scale_bytes
            or embedding.stat().st_size != 64 + rows * stride):
        raise ValueError("mapped embedding dimensions or format do not match the checkpoint")
    labels = manifest["labels"]
    checkpoint_labels = [model.config.id2label[i] for i in range(model.config.num_labels)]
    if checkpoint_labels != labels:
        raise ValueError("checkpoint label order differs from the mapped source")
    length = manifest["maxSequenceLength"]
    patch_modernbert_for_coreml_export(model, length)

    class Fused(torch.nn.Module):
        def __init__(self, classifier):
            super().__init__()
            self.model = classifier

        def forward(self, input_embeddings, attention_mask):
            return self.model(
                inputs_embeds=input_embeddings, attention_mask=attention_mask.long(), return_dict=True
            ).logits.softmax(-1)

    traced = torch.jit.trace(Fused(model).eval(), (
        torch.ones(1, length, width), torch.ones(1, length, dtype=torch.int32)
    ))
    converted = ct.convert(
        traced, convert_to="neuralnetwork", minimum_deployment_target=ct.target.iOS14,
        inputs=[ct.TensorType(name="input_embeddings", shape=(1, length, width), dtype=np.float32),
                ct.TensorType(name="attention_mask", shape=(1, length), dtype=np.int32)],
        classifier_config=ct.ClassifierConfig(labels),
    )
    output.mkdir(parents=True)
    target = output / manifest["modelArtifact"]
    converted.save(str(target))
    (target / EMBEDDING_PATH).parent.mkdir(parents=True, exist_ok=True)
    embedding_info = None
    if summary is None:
        shutil.copy2(embedding, target / EMBEDDING_PATH)
    else:
        quantized, scales = quantize_checkpoint_embeddings(
            model.get_input_embeddings().weight.detach().cpu().numpy(), block
        )
        embedding_info = write_embeddings(target / EMBEDDING_PATH, quantized, scales,
                                           scale_bytes=scale_bytes)
    shutil.copy2(tokenizer, output / tokenizer.name)
    candidate = unsigned_candidate_manifest(manifest)
    candidate.update(version=version, releaseSequence=sequence, minimumAppBuild=32,
                     releaseEligible=False, sha256=directory_sha256(target))
    candidate["runtimeProfile"].update(computeUnits="cpuOnly", modelType="neuralNetworkClassifier",
                                       computePrecision="float32")
    candidate["quantizationProfile"] = {
        "identifier": "nn-fp32-mapped-w4-block16", "weightBits": 32, "activationBits": 32,
        "method": "mixed", "granularity": "encoder-fp32-embedding-blockwise-int4", "blockSize": 16,
    }
    candidate["validationMetrics"] = {"fixedAccuracy": 0, "promotionAccuracy": 0,
                                      "fp16Agreement": 0, "languageAccuracy": {}}
    if summary is not None:
        candidate.update(trainedAt=summary["trainedAt"], trainingCount=summary["trainingCount"],
                         validationCount=summary["validationCount"], testCount=summary["testCount"])
        candidate["fineTuning"] = summary
        candidate.pop("quantizationSource", None)
        candidate["embeddingTransform"] = {
            **embedding_info, "input": "input_embeddings", "path": EMBEDDING_PATH,
            "sourceCheckpointSHA256": directory_sha256(checkpoint),
        }
    files = sorted(p for p in target.rglob("*") if p.is_file()) + [output / tokenizer.name]
    candidate["remoteArtifacts"] = [
        {"path": p.relative_to(output).as_posix(), "sha256": sha256(p), "byteCount": p.stat().st_size}
        for p in files
    ]
    candidate["downloadBytes"] = sum(item["byteCount"] for item in candidate["remoteArtifacts"])
    (output / "SiftSignalModel.manifest.json").write_text(json.dumps(candidate, indent=2) + "\n")
    (output / "export-provenance.json").write_text(json.dumps({
        "sourceArtifactSHA256": manifest["sha256"],
        "sourceManifestSHA256": sha256(source / "SiftSignalModel.manifest.json"),
        "checkpointFiles": {p.name: sha256(p) for p in sorted(checkpoint.iterdir())
                            if p.is_file() and (p.suffix == ".safetensors" or p.name == "config.json")},
        "exportedArtifactSHA256": candidate["sha256"],
        "rebuiltCheckpointEmbeddings": summary is not None,
        "trainingSummarySHA256": sha256(training_summary) if training_summary else None,
    }, indent=2) + "\n")
    return candidate


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--mapped-source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--release-sequence", type=int, required=True)
    parser.add_argument("--training-summary", type=Path,
                        help="replay fine-tuning summary; rebuilds mapped embeddings from the new checkpoint")
    args = parser.parse_args()
    result = export(args.checkpoint, args.mapped_source, args.out, args.version, args.release_sequence,
                    args.training_summary)
    print(f"unselected candidate: {result['sha256']} ({result['downloadBytes']} bytes)")


if __name__ == "__main__":
    main()
