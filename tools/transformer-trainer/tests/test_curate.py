"""Rule-tier unit tests for curate_dataset.py (stdlib only).

Run:  python3 -m unittest discover -s tests
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from curate_dataset import (  # noqa: E402
    detect_language,
    junk_reason,
    near_duplicate_signature,
    normalize,
    rehydrate_placeholders,
    stable_rng,
)


class DetectLanguageTests(unittest.TestCase):
    def test_core_languages(self):
        self.assertEqual(detect_language("您的验证码是 123456，请勿泄露。"), "zh")
        self.assertEqual(detect_language("Your verification code is 123456."), "en")
        self.assertEqual(detect_language("認証コードは 123456 です。"), "ja")

    def test_script_languages(self):
        self.assertEqual(detect_language("Ваш код подтверждения 123456"), "ru")
        self.assertEqual(detect_language("인증번호는 123456입니다"), "ko")
        self.assertEqual(detect_language("รหัสยืนยันของคุณคือ 123456"), "th")

    def test_latin_stopword_languages(self):
        self.assertEqual(detect_language("Tu código de verificación es 123456, gracias"), "es")
        self.assertEqual(detect_language("Ihr Konto wurde nicht belastet, bitte prüfen Sie"), "de")

    def test_kanji_only_japanese_falls_back_to_zh(self):
        # Known, documented limitation: pure-kanji ja text reads as zh.
        self.assertEqual(detect_language("会議室予約完了"), "zh")


class JunkReasonTests(unittest.TestCase):
    def test_length_bounds(self):
        self.assertEqual(junk_reason("short", "en", 8, 500), "too-short")
        self.assertEqual(junk_reason("x" * 501, "en", 8, 500), "too-long")

    def test_low_information(self):
        self.assertEqual(junk_reason("!!!???!!!???!!!", "en", 8, 500), "low-information")

    def test_repetitive(self):
        self.assertEqual(junk_reason("a" * 40, "en", 8, 500), "repetitive")

    def test_too_few_words_latin_only(self):
        self.assertEqual(junk_reason("congratulations", "en", 8, 500), "too-few-words")
        self.assertIsNone(junk_reason("您的快递已经到达驿站", "zh", 8, 500))

    def test_placeholder_only(self):
        self.assertEqual(junk_reason("{{PHONE}} {{CODE}}", "en", 8, 500), "placeholder-only")

    def test_normal_text_passes(self):
        self.assertIsNone(junk_reason("Your parcel arrived at Locker 4, code 482913.", "en", 8, 500))


class NearDuplicateTests(unittest.TestCase):
    def test_digit_variants_collapse(self):
        a = near_duplicate_signature("您的验证码是 123456，请勿泄露。")
        b = near_duplicate_signature("您的验证码是 987654，请勿泄露。")
        self.assertEqual(a, b)

    def test_different_texts_do_not_collapse(self):
        a = near_duplicate_signature("您的验证码是 123456")
        b = near_duplicate_signature("您的快递已经到达驿站")
        self.assertNotEqual(a, b)


class RehydrationTests(unittest.TestCase):
    def test_placeholders_replaced_deterministically(self):
        text = "请联系 {{PHONE}}，验证码 {{CODE}}，详情 {{URL}}"
        first = rehydrate_placeholders(text, "zh", stable_rng(text))
        second = rehydrate_placeholders(text, "zh", stable_rng(text))
        self.assertEqual(first, second, "same input must rehydrate identically")
        self.assertNotIn("{{", first)
        self.assertRegex(first, r"1\d{10}")

    def test_language_aware_values(self):
        amount_zh = rehydrate_placeholders("金额 {{AMOUNT}}", "zh", stable_rng("a"))
        amount_en = rehydrate_placeholders("Amount {{AMOUNT}}", "en", stable_rng("a"))
        self.assertIn("元", amount_zh)
        self.assertIn("$", amount_en)

    def test_id_placeholder(self):
        result = rehydrate_placeholders("证件号 {{ID}}", "zh", stable_rng("id"))
        self.assertNotIn("{{ID}}", result)


class NormalizeTests(unittest.TestCase):
    def test_whitespace_collapse(self):
        self.assertEqual(normalize("  a　\n b  "), "a b")


if __name__ == "__main__":
    unittest.main()
