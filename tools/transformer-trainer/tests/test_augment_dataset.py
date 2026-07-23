from __future__ import annotations

import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from augment_dataset import augment


class AugmentDatasetTests(unittest.TestCase):
    def test_adds_diverse_boundary_and_replacement_rows(self) -> None:
        base = [{
            "text": "No credit check loan asks for an upfront fee",
            "label": "spam",
            "language": "en",
            "source": "public:example",
            "sourceLabel": "loan_scam",
        }]
        config = {
            "schemaVersion": 1,
            "minimumSemanticChange": 0.01,
            "replacementRules": [{
                "id": "spam-en",
                "labels": ["spam"],
                "languages": ["en"],
                "replacements": [["upfront fee", "prepaid release charge"]],
            }],
            "boundaryRows": [{"family": "boundary", "label": "spam", "text": "Gift cards are required before loan payout"}],
        }

        rows, report = augment(base, config, {"spam"}, set(), set(), 10, 1, 42)

        self.assertEqual(len(rows), 3)
        self.assertEqual(report["augmentedCount"], 2)
        base_row = next(row for row in rows if row["text"] == base[0]["text"])
        self.assertEqual(base_row["source"], "public:example")
        self.assertEqual(base_row["sourceLabel"], "loan_scam")
        self.assertTrue(all(row.get("source") for row in rows))

    def test_rejects_holdout_digit_variant(self) -> None:
        base = [{"text": "Normal account status message", "label": "finance.bank", "language": "en"}]
        config = {
            "schemaVersion": 1,
            "boundaryRows": [{"family": "leak", "label": "spam", "text": "Unlock code 987654 before payout"}],
        }

        rows, report = augment(
            base,
            config,
            {"spam", "finance.bank"},
            set(),
            {"unlockcode0beforepayout"},
            10,
            1,
            42,
        )

        self.assertEqual(len(rows), 1)
        self.assertEqual(report["rejected"]["boundary:leak:holdout-near"], 1)

    def test_caps_augmented_rows_per_label(self) -> None:
        base = [{"text": "Normal account status message", "label": "finance.bank", "language": "en"}]
        config = {
            "schemaVersion": 1,
            "boundaryRows": [
                {"family": "a", "label": "spam", "text": "Send a deposit before receiving the private loan"},
                {"family": "b", "label": "spam", "text": "Buy a gift card before the promised payout arrives"},
            ],
        }

        _, report = augment(base, config, {"spam", "finance.bank"}, set(), set(), 1, 1, 42)

        self.assertEqual(report["augmentedByLabel"]["spam"], 1)
        self.assertEqual(report["rejected"]["boundary:label-cap"], 1)


if __name__ == "__main__":
    unittest.main()
