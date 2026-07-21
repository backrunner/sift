#!/usr/bin/env python3
"""Create leak-free, diversity-capped generalization rows for Sift training."""

from __future__ import annotations

import argparse
import difflib
import json
import random
from collections import Counter
from pathlib import Path
from typing import Any

from curate_dataset import (
    detect_language,
    load_taxonomy_labels,
    near_duplicate_signature,
    normalize,
    template_signature,
)
from model_contract import model_labels


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--config", type=Path, default=Path(__file__).with_name("generalization-augmentation.json"))
    parser.add_argument("--holdout", type=Path, action="append", required=True)
    parser.add_argument("--taxonomy", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--max-augmented-per-label", type=int, default=120)
    parser.add_argument("--max-variants-per-row", type=int, default=1)
    parser.add_argument("--seed", type=int, default=42)
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
            rows.append({"text": text, "label": label, "language": language})
    if not rows:
        raise SystemExit(f"error: dataset is empty: {path}")
    return rows


def load_holdout_keys(paths: list[Path]) -> tuple[set[str], set[str]]:
    exact: set[str] = set()
    near: set[str] = set()
    for path in paths:
        for row in load_rows(path):
            exact.add(row["text"].lower())
            near.add(near_duplicate_signature(row["text"]))
    return exact, near


def validate_config(config: dict[str, Any], valid_labels: set[str]) -> None:
    if config.get("schemaVersion") != 1:
        raise SystemExit("error: unsupported augmentation config schema")
    for rule in config.get("replacementRules", []):
        if not set(rule.get("labels", [])) <= valid_labels:
            raise SystemExit(f"error: augmentation rule has unknown label: {rule.get('id')}")
        if not rule.get("replacements"):
            raise SystemExit(f"error: augmentation rule has no replacements: {rule.get('id')}")
    for row in config.get("boundaryRows", []):
        if row.get("label") not in valid_labels or not normalize(str(row.get("text", ""))):
            raise SystemExit(f"error: invalid boundary augmentation row: {row}")


def semantic_change_fraction(first: str, second: str) -> float:
    return 1 - difflib.SequenceMatcher(a=first.lower(), b=second.lower()).ratio()


def augment(
    base_rows: list[dict[str, str]],
    config: dict[str, Any],
    valid_labels: set[str],
    holdout_exact: set[str],
    holdout_near: set[str],
    max_augmented_per_label: int,
    max_variants_per_row: int,
    seed: int,
) -> tuple[list[dict[str, str]], dict[str, Any]]:
    validate_config(config, valid_labels)
    exact_to_label: dict[str, str] = {}
    used_near: set[tuple[str, str]] = set()
    used_templates: set[tuple[str, str]] = set()
    output: list[dict[str, str]] = []
    rejected: Counter[str] = Counter()
    augmented_by_label: Counter[str] = Counter()
    augmented_by_family: Counter[str] = Counter()

    def retain(text: str, label: str, family: str, is_base: bool = False) -> bool:
        text = normalize(text)
        exact = text.lower()
        near = near_duplicate_signature(text)
        template = template_signature(text)
        if exact in holdout_exact:
            rejected[f"{family}:holdout-exact"] += 1
            return False
        if near in holdout_near:
            rejected[f"{family}:holdout-near"] += 1
            return False
        existing_label = exact_to_label.get(exact)
        if existing_label is not None and existing_label != label:
            rejected[f"{family}:cross-label-conflict"] += 1
            return False
        if (label, near) in used_near:
            rejected[f"{family}:near-duplicate"] += 1
            return False
        if template and (label, template) in used_templates:
            rejected[f"{family}:template-duplicate"] += 1
            return False
        output.append({"text": text, "label": label})
        exact_to_label[exact] = label
        used_near.add((label, near))
        if template:
            used_templates.add((label, template))
        if not is_base:
            augmented_by_label[label] += 1
            augmented_by_family[family] += 1
        return True

    for row in base_rows:
        if row["label"] not in valid_labels:
            raise SystemExit(f"error: base row has unknown label: {row['label']}")
        retain(row["text"], row["label"], "base", is_base=True)

    base_retained_count = len(output)

    for row in config.get("boundaryRows", []):
        label = row["label"]
        if augmented_by_label[label] >= max_augmented_per_label:
            rejected["boundary:label-cap"] += 1
            continue
        retain(row["text"], label, f"boundary:{row.get('family', 'unspecified')}")

    minimum_change = float(config.get("minimumSemanticChange", 0.04))
    rules = config.get("replacementRules", [])
    for row in base_rows:
        if augmented_by_label[row["label"]] >= max_augmented_per_label:
            continue
        variants = 0
        for rule in rules:
            if row["label"] not in rule.get("labels", []):
                continue
            if row["language"] not in rule.get("languages", []):
                continue
            for source, replacement in rule["replacements"]:
                if source not in row["text"]:
                    continue
                candidate = row["text"].replace(source, replacement, 1)
                if semantic_change_fraction(row["text"], candidate) < minimum_change:
                    rejected[f"replacement:{rule['id']}:too-similar"] += 1
                    continue
                if retain(candidate, row["label"], f"replacement:{rule['id']}"):
                    variants += 1
                if (
                    variants >= max_variants_per_row
                    or augmented_by_label[row["label"]] >= max_augmented_per_label
                ):
                    break
            if variants >= max_variants_per_row:
                break

    random.Random(seed).shuffle(output)
    report = {
        "schemaVersion": 1,
        "baseCount": len(base_rows),
        "baseRetainedCount": base_retained_count,
        "outputCount": len(output),
        "augmentedCount": sum(augmented_by_label.values()),
        "augmentedByLabel": dict(sorted(augmented_by_label.items())),
        "augmentedByFamily": dict(sorted(augmented_by_family.items())),
        "rejected": dict(sorted(rejected.items())),
        "maxAugmentedPerLabel": max_augmented_per_label,
        "maxVariantsPerRow": max_variants_per_row,
        "seed": seed,
    }
    return output, report


def main() -> None:
    arguments = parse_arguments()
    valid_labels = model_labels(load_taxonomy_labels(arguments.taxonomy))
    config = json.loads(arguments.config.read_text(encoding="utf-8"))
    base_rows = load_rows(arguments.input)
    holdout_exact, holdout_near = load_holdout_keys(arguments.holdout)
    output, report = augment(
        base_rows,
        config,
        valid_labels,
        holdout_exact,
        holdout_near,
        arguments.max_augmented_per_label,
        arguments.max_variants_per_row,
        arguments.seed,
    )
    arguments.out.parent.mkdir(parents=True, exist_ok=True)
    with arguments.out.open("w", encoding="utf-8") as handle:
        for row in output:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    arguments.report.parent.mkdir(parents=True, exist_ok=True)
    arguments.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
