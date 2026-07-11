#!/usr/bin/env python3
"""Build a leak-free classic/transformer candidate corpus.

The base corpus is preserved except for rows colliding with a holdout. The
supplement contributes only requested labels and is deduplicated against the
base, every holdout, and earlier supplement rows using the same digit-insensitive
signature as the curation pipeline.
"""

from __future__ import annotations

import argparse
import json
import random
import re
import unicodedata
from collections import Counter
from pathlib import Path


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--supplement", type=Path, required=True)
    parser.add_argument("--holdout", type=Path, action="append", required=True)
    parser.add_argument("--labels", default="promotion,carrier.promotion,transaction.message,spam")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=42)
    return parser.parse_args()


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", text)).strip()


def near_duplicate_signature(text: str) -> str:
    collapsed = re.sub(r"\d+", "0", normalize(text).lower())
    collapsed = re.sub(r"[\W_]+", "", collapsed, flags=re.UNICODE)
    return collapsed[:80]


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
            rows.append({"text": text, "label": label})
    return rows


def main() -> None:
    arguments = parse_arguments()
    selected_labels = {item.strip() for item in arguments.labels.split(",") if item.strip()}
    holdout_rows = [row for path in arguments.holdout for row in load_rows(path)]
    holdout_exact = {row["text"].lower() for row in holdout_rows}
    holdout_near = {near_duplicate_signature(row["text"]) for row in holdout_rows}

    retained: list[dict[str, str]] = []
    exact_to_label: dict[str, str] = {}
    label_exact: set[tuple[str, str]] = set()
    label_near: set[tuple[str, str]] = set()
    rejected = Counter()

    def retain(row: dict[str, str], source: str) -> None:
        exact = row["text"].lower()
        signature = near_duplicate_signature(row["text"])
        if exact in holdout_exact:
            rejected[f"{source}:holdout-exact"] += 1
            return
        if signature in holdout_near:
            rejected[f"{source}:holdout-near"] += 1
            return
        if exact in exact_to_label and exact_to_label[exact] != row["label"]:
            rejected[f"{source}:cross-label-conflict"] += 1
            return
        exact_key = (row["label"], exact)
        near_key = (row["label"], signature)
        if exact_key in label_exact:
            rejected[f"{source}:duplicate"] += 1
            return
        if near_key in label_near:
            rejected[f"{source}:near-duplicate"] += 1
            return
        retained.append(row)
        exact_to_label[exact] = row["label"]
        label_exact.add(exact_key)
        label_near.add(near_key)

    base_rows = load_rows(arguments.base)
    for row in base_rows:
        retain(row, "base")

    supplement_rows = load_rows(arguments.supplement)
    selected_supplement = [row for row in supplement_rows if row["label"] in selected_labels]
    for row in selected_supplement:
        retain(row, "supplement")

    random.Random(arguments.seed).shuffle(retained)
    arguments.out.parent.mkdir(parents=True, exist_ok=True)
    with arguments.out.open("w", encoding="utf-8") as handle:
        for row in retained:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")

    counts = Counter(row["label"] for row in retained)
    report = {
        "baseCount": len(base_rows),
        "supplementCount": len(supplement_rows),
        "selectedSupplementCount": len(selected_supplement),
        "holdoutCount": len(holdout_rows),
        "outputCount": len(retained),
        "outputLabelCounts": dict(sorted(counts.items())),
        "rejected": dict(sorted(rejected.items())),
        "nearDuplicateMethod": "NFC + lowercase + digit collapse + alnum-only + first 80 characters",
    }
    arguments.report.parent.mkdir(parents=True, exist_ok=True)
    arguments.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
