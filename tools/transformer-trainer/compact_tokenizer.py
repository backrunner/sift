#!/usr/bin/env python3
"""Convert a Hugging Face BPE tokenizer JSON into Sift's mmap format."""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path
from typing import Any


MAGIC = b"SIFTBPE1"
FORMAT_VERSION = 1
FNV_OFFSET = 14_695_981_039_346_656_037
FNV_PRIME = 1_099_511_628_211


def fnv1a64(value: bytes) -> int:
    result = FNV_OFFSET
    for byte in value:
        result ^= byte
        result = (result * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF
    return result


def pair_key(first_id: int, second_id: int) -> int:
    return ((first_id & 0xFFFFFFFF) << 32) | (second_id & 0xFFFFFFFF)


def write_compact_bpe_tokenizer(source: Path, destination: Path) -> Path:
    document = json.loads(source.read_text(encoding="utf-8"))
    model = document.get("model")
    if not isinstance(model, dict) or model.get("type") != "BPE":
        raise ValueError("tokenizer model must be BPE")

    vocabulary = model.get("vocab")
    merges = model.get("merges")
    if not isinstance(vocabulary, dict) or not isinstance(merges, list):
        raise ValueError("tokenizer must contain vocab and merges")

    tokens_by_id = [""] * len(vocabulary)
    for token, raw_id in vocabulary.items():
        if not isinstance(token, str) or not isinstance(raw_id, int):
            raise ValueError("invalid vocabulary entry")
        if raw_id < 0 or raw_id >= len(tokens_by_id) or tokens_by_id[raw_id]:
            raise ValueError("vocabulary ids must be dense and unique")
        tokens_by_id[raw_id] = token
    if any(not token for token in tokens_by_id):
        raise ValueError("vocabulary ids must be dense")

    unknown_token = model.get("unk_token") or "<unk>"
    unknown_id = require_token_id(vocabulary, unknown_token)
    begin_id = special_token_id(document, vocabulary, "<bos>")
    end_id = special_token_id(document, vocabulary, "<eos>")
    padding_id = require_token_id(vocabulary, "<pad>")
    flags = 1 if model.get("byte_fallback") else 0

    token_blob = bytearray()
    token_records: list[tuple[int, int]] = []
    hash_records: list[tuple[int, int]] = []
    for token_id, token in enumerate(tokens_by_id):
        encoded = token.encode("utf-8")
        token_records.append((len(token_blob), len(encoded)))
        token_blob.extend(encoded)
        hash_records.append((fnv1a64(encoded), token_id))
    hash_records.sort(key=lambda item: (item[0], tokens_by_id[item[1]].encode("utf-8"), item[1]))

    merge_records: list[tuple[int, int, int]] = []
    for rank, raw_merge in enumerate(merges):
        first, second = parse_merge(raw_merge)
        first_id = require_token_id(vocabulary, first)
        second_id = require_token_id(vocabulary, second)
        result_id = require_token_id(vocabulary, first + second)
        merge_records.append((pair_key(first_id, second_id), rank, result_id))
    merge_records.sort(key=lambda item: item[0])
    if len({item[0] for item in merge_records}) != len(merge_records):
        raise ValueError("merge pairs must be unique")

    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as handle:
        handle.write(MAGIC)
        handle.write(struct.pack(
            "<IIIIIIIIQ",
            FORMAT_VERSION,
            flags,
            len(tokens_by_id),
            len(merge_records),
            unknown_id,
            begin_id,
            end_id,
            padding_id,
            len(token_blob),
        ))
        for offset, length in token_records:
            handle.write(struct.pack("<II", offset, length))
        for token_hash, token_id in hash_records:
            handle.write(struct.pack("<QII", token_hash, token_id, 0))
        for key, rank, result_id in merge_records:
            handle.write(struct.pack("<QII", key, rank, result_id))
        handle.write(token_blob)
    return destination


def parse_merge(raw_merge: Any) -> tuple[str, str]:
    if isinstance(raw_merge, list) and len(raw_merge) == 2 and all(isinstance(item, str) for item in raw_merge):
        return raw_merge[0], raw_merge[1]
    if isinstance(raw_merge, str) and " " in raw_merge:
        first, second = raw_merge.split(" ", 1)
        return first, second
    raise ValueError("invalid merge entry")


def require_token_id(vocabulary: dict[str, int], token: str) -> int:
    token_id = vocabulary.get(token)
    if not isinstance(token_id, int):
        raise ValueError(f"token missing from vocabulary: {token!r}")
    return token_id


def special_token_id(document: dict[str, Any], vocabulary: dict[str, int], token: str) -> int:
    special = document.get("post_processor", {}).get("special_tokens", {}).get(token, {})
    ids = special.get("ids") if isinstance(special, dict) else None
    if isinstance(ids, list) and ids and isinstance(ids[0], int):
        return ids[0]
    return require_token_id(vocabulary, token)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    output = write_compact_bpe_tokenizer(arguments.source, arguments.destination)
    print(output)


if __name__ == "__main__":
    main()
