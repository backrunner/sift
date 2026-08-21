import random
import tempfile
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from train_pii import (
    FakePII,
    assert_no_placeholder_examples,
    contextualize_value,
    load_redaction_regressions,
    normalize_package_permissions,
    ordinary_code_negative,
    ordinary_grouped_number_negative,
    synthesize,
    synthesize_contextual_redaction_examples,
)


class PIISynthesisTests(unittest.TestCase):
    def test_contextual_redaction_synthesis_is_placeholder_free_and_multilingual(self) -> None:
        examples = synthesize_contextual_redaction_examples(600, random.Random(13), clean_fraction=0.25)

        self.assertEqual(len(examples), 600)
        self.assertTrue(any(not example["spans"] for example in examples))
        self.assertTrue(any(any(span[2] == "ID" for span in example["spans"]) for example in examples))
        self.assertTrue(any(any(span[2] == "NAME" for span in example["spans"]) for example in examples))
        self.assertTrue(any("微信" in example["text"] or "QQ号" in example["text"] for example in examples))
        self.assertTrue(any("Cloud account ID" in example["text"] for example in examples))
        self.assertTrue(any("アカウントID" in example["text"] or "表示名" in example["text"] for example in examples))
        assert_no_placeholder_examples(examples, "test-contextual")
        for example in examples:
            for start, end, tag in example["spans"]:
                self.assertIn(tag, ("ID", "NAME"))
                self.assertTrue(example["text"][start:end])

    def test_fixed_redaction_regressions_are_synthetic_and_have_train_eval_splits(self) -> None:
        path = Path(__file__).resolve().parent / "Evaluation/redaction-regressions.ndjson"
        examples = load_redaction_regressions(path)

        self.assertGreaterEqual(len(examples), 12)
        self.assertTrue(any(example["split"] == "train" for example in examples))
        self.assertTrue(any(example["split"] == "eval" for example in examples))
        self.assertTrue(any(span[2] == "ID" for example in examples for span in example["spans"]))
        self.assertTrue(any(not example["spans"] for example in examples))
        assert_no_placeholder_examples(examples, "test")

    def test_redaction_regression_loader_rejects_placeholder_markers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "bad.ndjson"
            path.write_text(
                '{"text":"QQ号：{{ID}}","spans":[],"split":"eval"}\n',
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                load_redaction_regressions(path)

    def test_exported_package_permissions_are_xcode_sandbox_readable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            package = Path(temporary_directory) / "Detector.mlpackage"
            weights = package / "Data/com.apple.CoreML/weights"
            weights.mkdir(parents=True)
            model = package / "Data/com.apple.CoreML/model.mlmodel"
            weight = weights / "weight.bin"
            model.write_bytes(b"model")
            weight.write_bytes(b"weights")
            weights.chmod(0o700)
            model.chmod(0o600)

            normalize_package_permissions(package)

            self.assertEqual(weights.stat().st_mode & 0o055, 0o055)
            self.assertEqual(model.stat().st_mode & 0o044, 0o044)
            self.assertEqual(weight.stat().st_mode & 0o044, 0o044)

    def test_amount_values_cover_thousands_separators_and_currency_context(self) -> None:
        amounts = [FakePII(random.Random(seed)).value("AMOUNT", seed % 2 == 0) for seed in range(100)]
        japanese_amounts = [FakePII(random.Random(seed)).value("AMOUNT", True, True) for seed in range(100)]

        self.assertTrue(any("," in amount for amount in amounts))
        self.assertTrue(any(amount.startswith(("¥", "￥")) or amount.endswith("元") for amount in amounts))
        self.assertTrue(any("USD" in amount or amount.startswith("$") for amount in amounts))
        for amount in amounts:
            self.assertTrue(any(marker in amount for marker in ("¥", "￥", "元", "$", "USD")))
        self.assertTrue(any(amount.endswith("円") for amount in japanese_amounts))
        self.assertTrue(any("JPY" in amount for amount in japanese_amounts))

    def test_code_values_always_have_authentication_context(self) -> None:
        examples = synthesize(["产品目录已经更新"] * 200, random.Random(7), clean_fraction=0)
        code_examples = [
            example for example in examples
            if any(span[2] == "CODE" for span in example["spans"])
        ]

        self.assertTrue(code_examples)
        for example in code_examples:
            self.assertTrue(any(keyword in example["text"] for keyword in ("验证码", "动态码", "一次性口令")))

    def test_context_wrapper_does_not_expand_the_sensitive_span(self) -> None:
        rendered, start, end = contextualize_value("CODE", "482913", "登录提醒", random.Random(1))

        self.assertEqual(rendered[start:end], "482913")
        self.assertNotEqual(rendered, "482913")

    def test_non_code_values_are_unchanged(self) -> None:
        rendered, start, end = contextualize_value("ORDER_ID", "SF123456", "物流提醒", random.Random(1))

        self.assertEqual((rendered, start, end), ("SF123456", 0, 8))

    def test_ordinary_code_negatives_have_no_sensitive_spans(self) -> None:
        rng = random.Random(9)
        negatives = [ordinary_code_negative(rng) for _ in range(100)]

        self.assertTrue(any("Error code" in text for text in negatives))
        self.assertTrue(any("故障代码" in text for text in negatives))
        self.assertTrue(any("障害コード" in text for text in negatives))

    def test_grouped_number_negatives_cover_all_languages_without_currency(self) -> None:
        rng = random.Random(11)
        negatives = [ordinary_grouped_number_negative(rng) for _ in range(200)]

        self.assertTrue(all("," in text for text in negatives))
        self.assertTrue(any("积分" in text for text in negatives))
        self.assertTrue(any("points" in text for text in negatives))
        self.assertTrue(any("ポイント" in text for text in negatives))
        self.assertTrue(all(not any(marker in text for marker in ("¥", "￥", "$", "元", "円", "USD")) for text in negatives))


if __name__ == "__main__":
    unittest.main()
