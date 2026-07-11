import random
import unittest

from train_pii import contextualize_value, ordinary_code_negative, synthesize


class PIISynthesisTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
