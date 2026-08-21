from __future__ import annotations

import unittest
import sys
import json
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from augment_dataset import augment, load_boundary_rows


class AugmentDatasetTests(unittest.TestCase):
    def test_loads_versioned_boundary_config(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "boundaries.json"
            path.write_text(json.dumps({
                "schemaVersion": 1,
                "boundaryRows": [{
                    "family": "v50",
                    "label": "promotion",
                    "text": "  Limited offer  ",
                    "language": "en",
                }],
            }), encoding="utf-8")

            self.assertEqual(load_boundary_rows([path]), [{
                "text": "Limited offer",
                "label": "promotion",
                "family": "v50",
                "language": "en",
            }])

    def test_rejects_non_string_boundary_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "boundaries.json"
            path.write_text(json.dumps({
                "schemaVersion": 1,
                "boundaryRows": [{"text": None, "label": "promotion"}],
            }), encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "requires string text and label"):
                load_boundary_rows([path])

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

    def test_promotes_existing_reviewed_boundary_without_duplicating_it(self) -> None:
        text = "Managed database db-one expires soon; renew it in the console"
        base = [{"text": text, "label": "work.alert", "language": "en"}]
        config = {
            "schemaVersion": 1,
            "boundaryRows": [{
                "family": "cloud-expiry",
                "label": "work.alert",
                "text": text,
            }],
        }

        rows, report = augment(base, config, {"work.alert"}, set(), set(), 10, 1, 42)

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["source"], "augmentation:boundary:cloud-expiry")
        self.assertEqual(report["augmentedCount"], 0)
        self.assertEqual(report["promotedBoundaryCount"], 1)

    def test_rejects_cross_label_template_variant(self) -> None:
        base = [{
            "text": "[Bank A] Loan 991122 approved. Visit https://a.example/x. Reply STOP to end",
            "label": "finance.bank",
            "language": "en",
        }]
        config = {
            "schemaVersion": 1,
            "boundaryRows": [{
                "family": "conflict",
                "label": "promotion",
                "text": "[Bank B] Loan 448899 approved. Visit https://b.example/y. Txt STOP",
            }],
        }

        rows, report = augment(
            base,
            config,
            {"finance.bank", "promotion"},
            set(),
            set(),
            10,
            1,
            42,
        )

        self.assertEqual(len(rows), 1)
        self.assertEqual(report["rejected"]["boundary:conflict:cross-label-template-conflict"], 1)


if __name__ == "__main__":
    unittest.main()
