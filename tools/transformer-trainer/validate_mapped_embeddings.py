#!/usr/bin/env python3
"""Compare transformed embeddings against the qualified model on external holdouts.

Read-only qualification evidence; never changes release eligibility or installs.
Run with the trainer venv on macOS. No network or training is performed.
"""
from __future__ import annotations

import argparse
import gc
import json
from pathlib import Path

from externalize_embeddings import EMBEDDING_INPUT, EMBEDDING_PATH, directory_sha256, read_embedding_rows, sha256
from quantize_candidates import encode_samples, language, predicted_label_and_probabilities


def validate(source: Path, candidates: list[Path], checkpoint: Path, output: Path) -> dict:
    import coremltools as ct
    import numpy as np
    from transformers import AutoTokenizer

    root = Path(__file__).resolve().parents[2]
    paths = {
        "fixed": root / "tools/apple-trainer/Evaluation/classification-regressions.ndjson",
        "promotion": root / "tools/apple-trainer/Evaluation/promotion-regressions.ndjson",
        "billing": root / "tools/apple-trainer/Evaluation/billing-card-regressions.ndjson",
        "conversation": root / "tools/transformer-trainer/Evaluation/conversation-regressions.ndjson",
    }
    datasets = {key: [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
                for key, path in paths.items()}
    manifest = json.loads((source / "SiftSignalModel.manifest.json").read_text())
    labels = manifest["labels"]
    tokenizer = AutoTokenizer.from_pretrained(checkpoint, local_files_only=True)
    samples = {key: encode_samples(tokenizer, rows, manifest["maxSequenceLength"])
               for key, rows in datasets.items()}
    report = {"computeUnits": "cpuOnly", "datasets": {
        key: {"rows": len(datasets[key]), "sha256": sha256(path)} for key, path in paths.items()
    }, "models": [], "releaseEligible": False}
    baseline = {}
    for directory in [source, *candidates]:
        current = json.loads((directory / "SiftSignalModel.manifest.json").read_text())
        package = directory / current["modelArtifact"]
        if current["labels"] != labels or directory_sha256(package) != current["sha256"]:
            raise ValueError("label contract or model checksum mismatch")
        if current["tokenizerSHA256"] != manifest["tokenizerSHA256"]:
            raise ValueError("tokenizer changed")
        model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
        mapped = package / EMBEDDING_PATH
        results = {"path": str(directory), "sha256": current["sha256"], "holdouts": {}}
        for key, rows in datasets.items():
            predictions, probabilities = [], []
            for sample in samples[key]:
                inputs = dict(sample)
                if mapped.exists():
                    inputs[EMBEDDING_INPUT] = read_embedding_rows(mapped, sample["input_ids"])
                label, scores = predicted_label_and_probabilities(model.predict(inputs), labels)
                if not np.isfinite(scores).all():
                    raise ValueError("non-finite probabilities")
                predictions.append(label)
                probabilities.append(scores)
            probabilities = np.asarray(probabilities)
            if directory == source:
                baseline[key] = (predictions, probabilities)
            expected_predictions, expected_probabilities = baseline[key]
            results["holdouts"][key] = {
                "count": len(rows),
                "correct": sum(p == row["label"] for p, row in zip(predictions, rows)),
                "changedPredictions": sum(a != b for a, b in zip(predictions, expected_predictions)),
                "maximumProbabilityDifference": float(np.max(np.abs(probabilities - expected_probabilities))),
                "languageAccuracy": {
                    lang: sum(p == r["label"] for p, r in zip(predictions, rows) if language(r["text"]) == lang)
                        / sum(language(r["text"]) == lang for r in rows)
                    for lang in sorted({language(r["text"]) for r in rows})
                },
            }
            print(directory.name, key, results["holdouts"][key], flush=True)
        report["models"].append(results)
        del model
        gc.collect()
    output.write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, action="append", required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    validate(args.source, args.candidate, args.checkpoint, args.output)
