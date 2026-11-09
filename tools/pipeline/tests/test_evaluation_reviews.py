import hashlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from review_evaluation import apply_reviews


class EvaluationReviewTests(unittest.TestCase):
    def test_review_changes_only_the_label_and_preserves_legacy_records(self):
        rows = [{"text": "A prepaid account balance", "label": "carrier.data_reminder"}]
        review = {"row": 1, "textSHA256": hashlib.sha256(rows[0]["text"].encode()).hexdigest(),
                  "previousLabel": "carrier.data_reminder", "reviewedLabel": "carrier.billing"}
        changed = apply_reviews(rows, [review])
        self.assertEqual(changed[0]["label"], "carrier.billing")
        self.assertEqual(changed[0]["text"], rows[0]["text"])
        self.assertEqual(rows[0]["label"], "carrier.data_reminder")

    def test_stale_review_or_duplicate_cannot_silently_relabel_another_case(self):
        rows = [{"text": "A different message", "label": "carrier.data_reminder"}]
        review = {"row": 1, "textSHA256": "not-the-current-text", "previousLabel": "carrier.data_reminder",
                  "reviewedLabel": "carrier.billing"}
        with self.assertRaises(ValueError):
            apply_reviews(rows, [review])
        review["textSHA256"] = hashlib.sha256(rows[0]["text"].encode()).hexdigest()
        with self.assertRaises(ValueError):
            apply_reviews(rows, [review, review])


if __name__ == "__main__":
    unittest.main()
