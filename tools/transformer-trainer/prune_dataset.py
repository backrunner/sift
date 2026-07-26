#!/usr/bin/env python3
"""Prune same-label semantic duplicates without weakening label boundaries.

Rows are compared only within the same language. Near-identical rows assigned
to different labels fail the run instead of being silently retained or moved.
Reviewed boundary rows are always preserved, and one anchor per replacement
family/language survives so synonym coverage is not lost to semantic pruning.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Callable

from curate_dataset import detect_language, normalize


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--rejected", type=Path, default=None)
    parser.add_argument(
        "--model",
        default="sentence-transformers/distiluse-base-multilingual-cased-v2",
    )
    parser.add_argument(
        "--similarity-threshold",
        type=float,
        default=0.96,
        help="same-label cosine similarity at which the lower-priority row is removed",
    )
    parser.add_argument(
        "--cross-label-threshold",
        type=float,
        default=0.96,
        help="same-language cross-label cosine similarity that fails the audit",
    )
    parser.add_argument(
        "--min-rows-per-label-language",
        type=int,
        default=20,
        help="minimum rows retained in every label/language bucket",
    )
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--scan-batch-size", type=int, default=512)
    return parser.parse_args()


def load_rows(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with path.open(encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            record = json.loads(line)
            text = normalize(str(record.get("text", "")))
            label = str(record.get("label", "")).strip()
            if not text or not label:
                raise SystemExit(f"error: invalid row at {path}:{number}")
            language = str(record.get("language", "")).strip() or detect_language(text)
            row = {"text": text, "label": label, "language": language}
            for key in ("source", "sourceLabel"):
                value = str(record.get(key, "")).strip()
                if value:
                    row[key] = value
            rows.append(row)
    if not rows:
        raise SystemExit(f"error: dataset is empty: {path}")
    return rows


def source_priority(row: dict[str, str]) -> int:
    """Prefer reviewed/observed language over generated surface variation."""
    source = row.get("source", "").casefold()
    if source.startswith("augmentation:boundary:"):
        return 0
    if "remote" in source or "cloudkit" in source:
        return 1
    if not source.startswith(("synthetic:", "augmentation:")):
        return 2
    if source.startswith("augmentation:replacement:"):
        return 3
    return 4


def stable_rank(index: int, row: dict[str, str], protected: set[int]) -> tuple[int, int, str]:
    digest = hashlib.sha256(
        f"{row['label']}\x1f{row['language']}\x1f{row.get('source', '')}\x1f{row['text']}".encode("utf-8")
    ).hexdigest()
    return (source_priority(row), 0 if index in protected else 1, digest)


def protected_indices(rows: list[dict[str, str]]) -> set[int]:
    protected = {
        index for index, row in enumerate(rows)
        if row.get("source", "").startswith("augmentation:boundary:")
    }
    replacement_buckets: dict[tuple[str, str, str], list[int]] = defaultdict(list)
    for index, row in enumerate(rows):
        source = row.get("source", "")
        if source.startswith("augmentation:replacement:"):
            replacement_buckets[(source, row["label"], row["language"])].append(index)
    for indices in replacement_buckets.values():
        protected.add(min(indices, key=lambda index: stable_rank(index, rows[index], set())))
    return protected


MaximumSimilarity = Callable[[int, list[int]], tuple[float, int | None]]


def select_group(
    indices: list[int],
    rows: list[dict[str, str]],
    protected: set[int],
    threshold: float,
    minimum_rows: int,
    maximum_similarity: MaximumSimilarity,
) -> tuple[list[int], list[tuple[int, int, float]]]:
    """Greedily select representatives from one label/language bucket."""
    ordered = sorted(indices, key=lambda index: stable_rank(index, rows[index], protected))
    selected: list[int] = []
    rejected: list[tuple[int, int, float]] = []
    for index in ordered:
        score, peer = maximum_similarity(index, selected)
        can_drop = len(indices) - len(rejected) > minimum_rows
        if index not in protected and peer is not None and score >= threshold and can_drop:
            rejected.append((index, peer, score))
        else:
            selected.append(index)
    return selected, rejected


def encode_rows(rows: list[dict[str, str]], model_name: str, batch_size: int) -> Any:
    try:
        import numpy as np
        import torch
        from sentence_transformers import SentenceTransformer
    except ImportError as error:
        raise SystemExit(
            "error: semantic pruning requires numpy, torch, and sentence-transformers; run with `uv run`"
        ) from error

    device = "cuda" if torch.cuda.is_available() else (
        "mps" if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available() else "cpu"
    )
    print(f"semantic pruning: embedding {len(rows)} rows with {model_name} on {device}")
    model = SentenceTransformer(model_name, device=device)
    return np.asarray(model.encode(
        [row["text"] for row in rows],
        batch_size=batch_size,
        normalize_embeddings=True,
        show_progress_bar=False,
    ))


def find_cross_label_conflicts(
    rows: list[dict[str, str]],
    embeddings: Any,
    threshold: float,
    batch_size: int,
) -> list[tuple[int, int, float]]:
    """Return each high-similarity same-language/cross-label pair once."""
    import numpy as np

    by_language: dict[str, list[int]] = defaultdict(list)
    for index, row in enumerate(rows):
        by_language[row["language"]].append(index)

    conflicts: list[tuple[int, int, float]] = []
    for indices in by_language.values():
        index_array = np.asarray(indices)
        labels = np.asarray([rows[index]["label"] for index in indices])
        for start in range(0, len(indices), batch_size):
            left = index_array[start:start + batch_size]
            similarities = embeddings[left] @ embeddings[index_array].T
            for offset, first in enumerate(left):
                valid = (index_array > first) & (labels != rows[int(first)]["label"])
                for position in np.flatnonzero(valid & (similarities[offset] >= threshold)):
                    conflicts.append((int(first), int(index_array[position]), float(similarities[offset, position])))
    return conflicts


def prune_rows(
    rows: list[dict[str, str]],
    embeddings: Any,
    threshold: float,
    minimum_rows: int,
) -> tuple[list[dict[str, str]], list[dict[str, Any]], set[int]]:
    protected = protected_indices(rows)
    buckets: dict[tuple[str, str], list[int]] = defaultdict(list)
    for index, row in enumerate(rows):
        buckets[(row["label"], row["language"])].append(index)

    retained: set[int] = set()
    rejected: list[dict[str, Any]] = []
    for (label, language), indices in sorted(buckets.items()):
        def maximum_similarity(index: int, selected: list[int]) -> tuple[float, int | None]:
            if not selected:
                return -1.0, None
            scores = embeddings[selected] @ embeddings[index]
            position = int(scores.argmax())
            return float(scores[position]), selected[position]

        selected, removed = select_group(
            indices,
            rows,
            protected,
            threshold,
            minimum_rows,
            maximum_similarity,
        )
        retained.update(selected)
        for index, peer, score in removed:
            rejected.append({
                **rows[index],
                "reason": "same-label-semantic-duplicate",
                "similarity": round(score, 6),
                "duplicateOf": rows[peer]["text"],
                "duplicateOfSource": rows[peer].get("source", ""),
                "bucket": f"{label}\x1f{language}",
            })
    return [row for index, row in enumerate(rows) if index in retained], rejected, protected


def main() -> None:
    arguments = parse_arguments()
    if not 0 < arguments.similarity_threshold <= 1:
        raise SystemExit("error: --similarity-threshold must be in (0, 1]")
    if not 0 < arguments.cross_label_threshold <= 1:
        raise SystemExit("error: --cross-label-threshold must be in (0, 1]")
    if arguments.min_rows_per_label_language < 1:
        raise SystemExit("error: --min-rows-per-label-language must be positive")

    rows = load_rows(arguments.input)
    embeddings = encode_rows(rows, arguments.model, arguments.batch_size)
    conflicts = find_cross_label_conflicts(
        rows,
        embeddings,
        arguments.cross_label_threshold,
        arguments.scan_batch_size,
    )
    if conflicts:
        examples = [{
            "similarity": round(score, 6),
            "first": rows[first],
            "second": rows[second],
        } for first, second, score in sorted(conflicts, key=lambda item: -item[2])[:20]]
        arguments.report.parent.mkdir(parents=True, exist_ok=True)
        arguments.report.write_text(json.dumps({
            "inputCount": len(rows),
            "outputCount": None,
            "crossLabelConflictCount": len(conflicts),
            "crossLabelConflicts": examples,
            "status": "failed-cross-label-audit",
        }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        first = examples[0]
        raise SystemExit(
            "error: semantic cross-label audit failed with "
            f"{len(conflicts)} pair(s); highest similarity {first['similarity']}: "
            f"{first['first']['label']} <> {first['second']['label']}"
        )

    output, rejected, protected = prune_rows(
        rows,
        embeddings,
        arguments.similarity_threshold,
        arguments.min_rows_per_label_language,
    )
    removed_by_bucket = Counter(item["bucket"] for item in rejected)
    removed_by_source = Counter(item.get("source", "") for item in rejected)
    report = {
        "schemaVersion": 1,
        "inputCount": len(rows),
        "outputCount": len(output),
        "removedCount": len(rejected),
        "removedFraction": round(len(rejected) / len(rows), 6),
        "model": arguments.model,
        "similarityThreshold": arguments.similarity_threshold,
        "crossLabelThreshold": arguments.cross_label_threshold,
        "minRowsPerLabelLanguage": arguments.min_rows_per_label_language,
        "protectedBoundaryRows": sum(
            row.get("source", "").startswith("augmentation:boundary:") for row in rows
        ),
        "protectedReplacementAnchors": sum(
            index in protected and row.get("source", "").startswith("augmentation:replacement:")
            for index, row in enumerate(rows)
        ),
        "crossLabelConflictCount": 0,
        "removedByLabelLanguage": dict(sorted(removed_by_bucket.items())),
        "removedBySource": dict(sorted(removed_by_source.items())),
    }

    arguments.out.parent.mkdir(parents=True, exist_ok=True)
    with arguments.out.open("w", encoding="utf-8") as handle:
        for row in output:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    arguments.report.parent.mkdir(parents=True, exist_ok=True)
    arguments.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if arguments.rejected:
        arguments.rejected.parent.mkdir(parents=True, exist_ok=True)
        with arguments.rejected.open("w", encoding="utf-8") as handle:
            for row in rejected:
                handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
