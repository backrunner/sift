#!/usr/bin/env python3
"""Materialize explicitly reviewed expectations without editing a legacy dataset."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path


def apply_reviews(rows: list[dict], reviews: list[dict]) -> list[dict]:
    output = copy.deepcopy(rows)
    seen = set()
    for review in reviews:
        index = review["row"] - 1
        if index in seen or not 0 <= index < len(rows):
            raise ValueError("duplicate or invalid reviewed row")
        seen.add(index)
        row = rows[index]
        digest = hashlib.sha256(row["text"].encode("utf-8")).hexdigest()
        if digest != review["textSHA256"] or row["label"] != review["previousLabel"]:
            raise ValueError("review no longer matches the legacy text and label")
        output[index]["label"] = review["reviewedLabel"]
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--reviews", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.dataset.resolve() == args.out.resolve():
        parser.error("reviewed output must not overwrite the legacy dataset")
    root = Path(__file__).resolve().parents[2]
    name = args.dataset.resolve().relative_to(root).as_posix()
    manifest = json.loads(args.reviews.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1:
        parser.error("unsupported evaluation review schema")
    reviews = [r for r in manifest["reviews"] if r["dataset"] == name]
    rows = [json.loads(line) for line in args.dataset.read_text(encoding="utf-8").splitlines() if line.strip()]
    output = apply_reviews(rows, reviews)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in output), encoding="utf-8")
    print(json.dumps({"rows": len(rows), "reviewedLabels": len(reviews),
                      "sourceSHA256": hashlib.sha256(args.dataset.read_bytes()).hexdigest(),
                      "reviewsSHA256": hashlib.sha256(args.reviews.read_bytes()).hexdigest(),
                      "outputSHA256": hashlib.sha256(args.out.read_bytes()).hexdigest()}))


if __name__ == "__main__":
    main()
