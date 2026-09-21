import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from classic_gate import require_non_regression


class ClassicComparisonTests(unittest.TestCase):
    def setUp(self) -> None:
        self.baseline = {
            "suiteVersion": 2,
            "modelSHA256": "a" * 64,
            "datasetSHA256": {suite: "c" * 64 for suite in ("fixed", "promotion", "billing", "conversation")},
            "confidenceThreshold": 0.62,
            "benignOrTransactionToJunk": 0,
            "fixed": {"count": 487, "rawLabelAccuracy": 482 / 487, "actionAccuracy": 483 / 487},
            "promotion": {"count": 150, "rawLabelAccuracy": 0.98, "actionAccuracy": 148 / 150},
            "billing": {"count": 30, "rawLabelAccuracy": 1.0, "actionAccuracy": 1.0},
            "conversation": {"count": 30, "rawLabelAccuracy": 1.0, "actionAccuracy": 1.0},
        }
        self.candidate = copy.deepcopy(self.baseline)
        self.candidate["modelSHA256"] = "b" * 64

    def test_accepts_improvement_without_regressing_another_suite(self) -> None:
        self.candidate["promotion"]["rawLabelAccuracy"] = 1.0
        result = require_non_regression(self.candidate, self.baseline)
        self.assertTrue(result["passed"])
        self.assertAlmostEqual(result["deltas"]["promotion"]["rawLabelAccuracy"], 0.02)

    def test_rejects_r33_even_though_absolute_minimum_gates_pass(self) -> None:
        self.candidate["fixed"].update(rawLabelAccuracy=478 / 487, actionAccuracy=479 / 487)
        self.candidate["promotion"].update(rawLabelAccuracy=0.96, actionAccuracy=0.98)
        with self.assertRaisesRegex(SystemExit, "regresses.*fixed.rawLabelAccuracy.*promotion.rawLabelAccuracy"):
            require_non_regression(self.candidate, self.baseline)

    def test_raw_accuracy_improvement_cannot_hide_worse_routing(self) -> None:
        self.candidate["fixed"].update(rawLabelAccuracy=1.0, actionAccuracy=482 / 487)
        with self.assertRaisesRegex(SystemExit, "fixed.actionAccuracy"):
            require_non_regression(self.candidate, self.baseline)

    def test_rejects_comparison_of_different_data_or_thresholds(self) -> None:
        for key, value in (("datasetSHA256", {"fixed": "d" * 64}), ("confidenceThreshold", 0.50)):
            with self.subTest(key=key):
                candidate = copy.deepcopy(self.candidate)
                candidate[key] = value
                with self.assertRaises(SystemExit):
                    require_non_regression(candidate, self.baseline)

    def test_rejects_missing_identity_invalid_scores_and_unsafe_junk(self) -> None:
        for score in (None, float("nan"), float("inf"), -0.1, 1.1, True):
            with self.subTest(score=score):
                candidate = copy.deepcopy(self.candidate)
                candidate["promotion"]["rawLabelAccuracy"] = score
                with self.assertRaises(SystemExit):
                    require_non_regression(candidate, self.baseline)
        for key, value in (("modelSHA256", ""), ("benignOrTransactionToJunk", 1)):
            candidate = copy.deepcopy(self.candidate)
            candidate[key] = value
            with self.assertRaises(SystemExit):
                require_non_regression(candidate, self.baseline)


if __name__ == "__main__":
    unittest.main()
