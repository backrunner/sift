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

from externalize_embeddings import EMBEDDING_PATH, MODEL_ABI, directory_sha256, sha256
from check_distillation_gate import validate_distillation_provenance


def export(checkpoint: Path, source: Path, output: Path, version: str, sequence: int) -> dict:
    import coremltools as ct
    import numpy as np
    import torch
    from transformers import AutoModelForSequenceClassification
    from train_mmbert import patch_modernbert_for_coreml_export

    if output.exists():
        raise ValueError("output already exists; use a new candidate directory")
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
    shutil.copy2(embedding, target / EMBEDDING_PATH)
    shutil.copy2(tokenizer, output / tokenizer.name)
    candidate = copy.deepcopy(manifest)
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
    }, indent=2) + "\n")
    return candidate


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--mapped-source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--release-sequence", type=int, required=True)
    args = parser.parse_args()
    result = export(args.checkpoint, args.mapped_source, args.out, args.version, args.release_sequence)
    print(f"unselected candidate: {result['sha256']} ({result['downloadBytes']} bytes)")


if __name__ == "__main__":
    main()
