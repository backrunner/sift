import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from compact_tokenizer import MAGIC, fnv1a64, pair_key, write_compact_bpe_tokenizer


class CompactTokenizerTests(unittest.TestCase):
    def test_writes_dense_lookup_and_merge_records(self) -> None:
        document = {
            "model": {
                "type": "BPE",
                "vocab": {
                    "<pad>": 0,
                    "<eos>": 1,
                    "<bos>": 2,
                    "<unk>": 3,
                    "a": 4,
                    "b": 5,
                    "ab": 6,
                },
                "merges": [["a", "b"]],
                "byte_fallback": False,
                "unk_token": "<unk>",
            },
            "post_processor": {
                "special_tokens": {
                    "<bos>": {"ids": [2], "tokens": ["<bos>"]},
                    "<eos>": {"ids": [1], "tokens": ["<eos>"]},
                }
            },
        }

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "tokenizer.json"
            destination = root / "tokenizer.siftbpe"
            source.write_text(json.dumps(document), encoding="utf-8")
            write_compact_bpe_tokenizer(source, destination)
            data = destination.read_bytes()

        self.assertEqual(data[:8], MAGIC)
        header = struct.unpack_from("<IIIIIIIIQ", data, 8)
        self.assertEqual(header[:8], (1, 0, 7, 1, 3, 2, 1, 0))

        token_records_offset = 48
        hash_records_offset = token_records_offset + 7 * 8
        merge_records_offset = hash_records_offset + 7 * 16
        hashes = [struct.unpack_from("<QII", data, hash_records_offset + index * 16) for index in range(7)]
        self.assertEqual([item[0] for item in hashes], sorted(item[0] for item in hashes))
        self.assertIn((fnv1a64(b"ab"), 6, 0), hashes)
        self.assertEqual(struct.unpack_from("<QII", data, merge_records_offset), (pair_key(4, 5), 0, 6))


if __name__ == "__main__":
    unittest.main()
