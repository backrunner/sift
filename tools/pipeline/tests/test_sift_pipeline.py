import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import sift_pipeline as pipeline  # noqa: E402


class HoldoutIsolationTests(unittest.TestCase):
    def test_transformer_defaults_preserve_full_release_model(self) -> None:
        with patch.object(sys, "argv", ["sift_pipeline.py", "train-transformer"]):
            arguments = pipeline.parse_arguments()

        self.assertEqual(arguments.truncate_layers, 0)
        self.assertEqual(arguments.max_sequence_length, 96)

    def test_training_guard_rejects_exact_and_digit_normalized_collisions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixed = root / "fixed.ndjson"
            promotion = root / "promotion.ndjson"
            training = root / "training.ndjson"
            self.write_rows(fixed, ["Your verification code is 123456 and expires soon."])
            self.write_rows(promotion, ["Weekend sale saves 20 percent on groceries."])

            original_fixed = pipeline.CLASSIFICATION_TEST_SET
            original_promotion = pipeline.PROMOTION_TEST_SET
            pipeline.CLASSIFICATION_TEST_SET = fixed
            pipeline.PROMOTION_TEST_SET = promotion
            try:
                self.write_rows(training, [
                    "Your verification code is 123456 and expires soon.",
                    "Your verification code is 987654 and expires soon.",
                ])
                with self.assertRaisesRegex(SystemExit, "1 exact and 1 near"):
                    pipeline.require_holdout_isolation(training)

                self.write_rows(training, ["Your parcel is ready at locker 4."])
                pipeline.require_holdout_isolation(training)
            finally:
                pipeline.CLASSIFICATION_TEST_SET = original_fixed
                pipeline.PROMOTION_TEST_SET = original_promotion

    @staticmethod
    def write_rows(path: Path, texts: list[str]) -> None:
        payload = "\n".join(json.dumps({"text": text, "label": "test"}) for text in texts)
        path.write_text(payload + "\n", encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
