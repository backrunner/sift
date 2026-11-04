import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from export_neuralnetwork import quantize_checkpoint_embeddings, unsigned_candidate_manifest


class CandidateManifestTests(unittest.TestCase):
    def test_derived_candidate_cannot_inherit_signature_or_quality_evidence(self):
        source = {"signature": "old", "keyID": "release", "remoteBaseURL": "https://example.com",
                  "releaseEligible": True, "validationMetrics": {"fixedAccuracy": 1}, "validationAccuracy": 1.,
                  "deviceMetrics": {"peak": 1}, "labels": ["allow", "spam"]}
        candidate = unsigned_candidate_manifest(source)
        self.assertNotIn("signature", candidate)
        self.assertNotIn("keyID", candidate)
        self.assertNotIn("remoteBaseURL", candidate)
        self.assertNotIn("deviceMetrics", candidate)
        self.assertNotIn("validationAccuracy", candidate)
        self.assertFalse(candidate["releaseEligible"])
        self.assertEqual(candidate["validationMetrics"]["fixedAccuracy"], 0)
        self.assertEqual(source["signature"], "old")


@unittest.skipUnless(importlib.util.find_spec("numpy"), "requires trainer numpy")
class RebuiltEmbeddingTests(unittest.TestCase):
    def test_block_quantization_handles_zero_rows_and_matches_mapped_reader(self):
        import numpy as np
        from externalize_embeddings import read_embedding_rows, write_embeddings

        weights = np.array([[0, 0, 0, 0], [-2, 1, -4, 3], [1, -1, 2, -2]], dtype=np.float32)
        q, scales = quantize_checkpoint_embeddings(weights, 2)
        np.testing.assert_array_equal(q[0], 0)
        np.testing.assert_array_equal(scales[0], 0)
        reconstructed = q.astype(np.float32) * np.repeat(scales, 2, axis=1)
        self.assertTrue(np.all(np.abs(weights - reconstructed) <= np.repeat(scales, 2, axis=1) / 2 + 1e-6))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "embedding"
            write_embeddings(path, q, scales, scale_bytes=2)
            expected = q.astype(np.float32) * np.repeat(scales.astype(np.float16).astype(np.float32), 2, axis=1)
            np.testing.assert_array_equal(read_embedding_rows(path, [1, 0, 2]), expected[[1, 0, 2]])

    def test_invalid_or_nonfinite_embedding_cannot_be_exported(self):
        for weights, block in [([[float("nan"), 0]], 2), ([[0, 0, 0]], 2), ([], 2)]:
            with self.subTest(weights=weights), self.assertRaises(ValueError):
                quantize_checkpoint_embeddings(weights, block)


if __name__ == "__main__":
    unittest.main()
