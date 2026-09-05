import struct
import tempfile
import unittest
from pathlib import Path

try:
    import numpy as np
except ImportError:
    np = None

from externalize_embeddings import read_embedding_rows, write_embeddings


@unittest.skipIf(np is None, "requires trainer numpy environment")
class MappedEmbeddingTests(unittest.TestCase):
    def test_signed_int4_and_block_scales_round_trip_exactly(self):
        q = np.arange(-8, 8, dtype=np.int8).reshape(2, 8)
        scales = np.array([[0.5, 2], [0.25, 1]], dtype=np.float32)
        for precision in (2, 4):
            with self.subTest(precision=precision), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "embedding"
                report = write_embeddings(path, q, scales, scale_bytes=precision)
                self.assertEqual(report["byteCount"], 64 + 2 * (4 + 2 * precision))
                ids = np.array([[1, 0, 1]], dtype=np.int32)
                expected = (q.astype(np.float32) * np.repeat(scales, 4, axis=1))[ids]
                np.testing.assert_array_equal(read_embedding_rows(path, ids), expected)
                self.assertEqual(path.read_bytes()[64], 0x98)

    def test_fp16_storage_uses_rounded_scales_with_fp32_multiplication(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "embedding"
            q = np.array([[-8, -1, 0, 7]], dtype=np.int8)
            scales = np.array([[0.02617636, 0.00158241]], dtype=np.float32)
            write_embeddings(path, q, scales, scale_bytes=2)
            expected = q.astype(np.float32) * np.repeat(scales.astype(np.float16).astype(np.float32), 2, axis=1)
            np.testing.assert_array_equal(read_embedding_rows(path, [0]), expected)

    def test_writer_rejects_lossy_quantized_values_and_nonfinite_scales(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "embedding"
            for q, scales in [([[8, 0]], [[1]]), ([[-9, 0]], [[1]]),
                              ([[0.5, 1]], [[1]]), ([[0, 1]], [[float("nan")]]),
                              ([[0, 1]], [[1e10]]), ([[0, 1]], [[1e-20]])]:
                with self.subTest(q=q, scales=scales), self.assertRaises(ValueError):
                    with np.errstate(over="ignore", under="ignore"):
                        write_embeddings(path, q, scales, scale_bytes=2)

    def test_reader_rejects_bad_header_truncation_and_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "embedding"
            write_embeddings(path, [[-8, 7]], [[0.5]])
            valid = path.read_bytes()
            for ids in [[-1], [1], [2**31 - 1], [0.5]]:
                with self.subTest(ids=ids), self.assertRaises(ValueError):
                    read_embedding_rows(path, ids)
            corrupt = [b"", valid[:63], valid[:-1], valid + b"x"]
            for offset, value in [(0, 0), (8, 2), (20, 0), (24, 3), (28, 0), (32, 1)]:
                data = bytearray(valid)
                data[offset] = value
                corrupt.append(data)
            for data in corrupt:
                path.write_bytes(data)
                with self.assertRaises(ValueError):
                    read_embedding_rows(path, [0])
            path.write_bytes(valid[:65] + struct.pack("<f", float("inf")))
            with self.assertRaises(ValueError):
                read_embedding_rows(path, [0])
