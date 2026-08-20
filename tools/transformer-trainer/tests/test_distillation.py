from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from check_distillation_gate import compare_reports
from distill_mmbert import checkpoint_labels, runtime_validation_metrics, validate_label_contract


def report(*, promotion: float = 0.99, fixed: float = 0.995, readable: bool = True) -> dict:
    return {
        "metrics": {
            "fixedAccuracy": fixed,
            "promotionAccuracy": promotion,
            "billingAccuracy": 0.95,
            "billingActionAccuracy": 1.0,
            "conversationAccuracy": 1.0,
            "conversationActionAccuracy": 1.0,
            "probabilitiesFinite": True,
            "probabilitySumsValid": True,
            "languageAccuracy": {"en": 0.99, "ja": 0.99, "zh": 0.99},
        },
        "messageFilterActions": {
            "fixedAccuracy": fixed,
            "promotionAccuracy": promotion,
            "benignOrTransactionToJunk": 0,
            "readableCases": [{"passed": readable}],
        },
    }


class DistillationTests(unittest.TestCase):
    def test_teacher_label_mapping_is_dense_and_ordered(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            checkpoint = Path(temporary_directory)
            (checkpoint / "config.json").write_text(
                json.dumps({"id2label": {"0": "__sift_abstain__", "1": "spam"}}),
                encoding="utf-8",
            )

            self.assertEqual(checkpoint_labels(checkpoint), ["__sift_abstain__", "spam"])

    def test_label_contract_requires_the_selected_taxonomy_exactly(self) -> None:
        with self.assertRaisesRegex(SystemExit, "selected taxonomy contract"):
            validate_label_contract(
                ["__sift_abstain__", "spam"],
                {"__sift_abstain__", "spam"},
                {"spam", "government.reminder"},
            )

        validate_label_contract(
            ["__sift_abstain__", "spam"],
            {"__sift_abstain__", "spam"},
            {"spam"},
        )

    def test_runtime_validation_metrics_match_the_swift_manifest_contract(self) -> None:
        self.assertEqual(
            runtime_validation_metrics(0.98),
            {
                "fixedAccuracy": 0.0,
                "promotionAccuracy": 0.98,
                "fp16Agreement": 0.0,
                "languageAccuracy": {},
            },
        )

    def test_gate_allows_two_percent_absolute_loss(self) -> None:
        result = compare_reports(report(), report(promotion=0.97, fixed=0.975))

        self.assertTrue(result["passed"])
        self.assertAlmostEqual(result["metrics"]["promotionAccuracy"]["loss"], 0.02)

    def test_gate_rejects_quality_loss_and_readable_failure(self) -> None:
        result = compare_reports(report(), report(promotion=0.969, fixed=0.975, readable=False))

        self.assertFalse(result["passed"])
        self.assertTrue(any("promotionAccuracy" in failure for failure in result["failures"]))
        self.assertIn("student readable message-filter case failed", result["failures"])


if __name__ == "__main__":
    unittest.main()
