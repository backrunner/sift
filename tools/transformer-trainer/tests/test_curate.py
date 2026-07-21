"""Rule-tier unit tests for curate_dataset.py (stdlib only).

Run:  python3 -m unittest discover -s tests
"""

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from curate_dataset import (  # noqa: E402
    Report,
    Row,
    apply_rule_tier,
    detect_language,
    is_placeholder_only,
    junk_reason,
    near_duplicate_signature,
    normalize,
    normalize_language_hint,
    load_rows,
    rehydrate_placeholders,
    stable_rng,
    template_signature,
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

    def test_cloudkit_language_hints_are_normalized(self):
        self.assertEqual(normalize_language_hint("zh-Hans"), "zh")
        self.assertEqual(normalize_language_hint("ja_JP"), "ja")
        self.assertEqual(normalize_language_hint("eng"), "en")
        self.assertEqual(normalize_language_hint(None), "unknown")

    def test_null_cloudkit_hint_falls_back_to_source_language(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rows.ndjson"
            path.write_text(json.dumps({
                "text": "会議室予約完了",
                "label": "work.meeting",
                "textLanguage": None,
                "language": "ja-JP",
            }, ensure_ascii=False) + "\n", encoding="utf-8")

            rows = load_rows([path], Report())

        self.assertEqual(rows[0].language, "ja")

    def test_cloudkit_quality_metadata_is_loaded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "remote-training.ndjson"
            path.write_text(json.dumps({
                "text": "A deliberately corrected banking message",
                "label": "spam",
                "textLanguage": "en",
                "predictedLabel": "finance.bank",
                "predictedConfidence": 0.97,
                "agreement": 0,
                "modelVersion": "classic-v7",
                "schemaVersion": 2,
            }) + "\n", encoding="utf-8")

            row = load_rows([path], Report())[0]

        self.assertEqual(row.predicted_label, "finance.bank")
        self.assertEqual(row.predicted_confidence, 0.97)
        self.assertEqual(row.agreement, 0)


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
        self.assertEqual(junk_reason("{{PHONE}} {{PLATE}}", "en", 8, 500), "placeholder-only")
        self.assertTrue(is_placeholder_only("{{PHONE}} / {{PLATE}}"))
        self.assertFalse(is_placeholder_only("Call {{PHONE}} about vehicle {{PLATE}}"))

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

    def test_template_signature_removes_brand_dynamic_values_and_opt_out_footer(self):
        first = template_signature("[Bank A] Loan 991122 approved. Visit https://a.example/x. Reply STOP to end")
        second = template_signature("[Bank B] Loan 448899 approved. Visit https://b.example/y. Txt STOP")
        self.assertEqual(first, second)


class RuleTierTests(unittest.TestCase):
    def test_placeholder_only_rows_are_rejected_before_rehydration(self):
        report = Report()
        rejected: list[dict] = []
        arguments = SimpleNamespace(min_length=8, max_length=500)

        kept = apply_rule_tier(
            [Row(text="{{PHONE}} / {{PLATE}}", label="test.label", source="remote.ndjson")],
            {"test.label"},
            {"en"},
            arguments,
            report,
            rejected,
        )

        self.assertEqual(kept, [])
        self.assertEqual(report.rejected["placeholder-only"], 1)

    def test_contextual_placeholders_are_rehydrated_and_kept(self):
        report = Report()
        rejected: list[dict] = []
        arguments = SimpleNamespace(min_length=8, max_length=500)

        kept = apply_rule_tier(
            [Row(text="Call {{PHONE}} about vehicle {{PLATE}}", label="test.label", source="remote.ndjson")],
            {"test.label"},
            {"en"},
            arguments,
            report,
            rejected,
        )

        self.assertEqual(len(kept), 1)
        self.assertNotIn("{{", kept[0].text)
        self.assertEqual(report.rehydrated_rows, 1)

    def test_cloudkit_language_hint_controls_rehydration(self):
        report = Report()
        rejected: list[dict] = []
        arguments = SimpleNamespace(min_length=8, max_length=500)
        row = Row(
            text="駐車予約完了。車両番号 {{PLATE}}",
            label="test.label",
            source="remote.ndjson",
            language="ja",
        )

        kept = apply_rule_tier([row], {"test.label"}, {"ja"}, arguments, report, rejected)

        self.assertEqual(len(kept), 1)
        self.assertRegex(kept[0].text, r"(?:品川|練馬|横浜|大阪|神戸) \d{3} [ぁ-ん] \d{2}-\d{2}")

    def test_external_holdout_exact_and_digit_variants_are_rejected(self):
        report = Report()
        rejected: list[dict] = []
        arguments = SimpleNamespace(min_length=8, max_length=500)
        holdout = "Your verification code is 123456 and expires soon."
        rows = [
            Row(text=holdout, label="test.label", source="remote.ndjson"),
            Row(
                text="Your verification code is 987654 and expires soon.",
                label="test.label",
                source="remote.ndjson",
            ),
            Row(text="Your parcel is ready at locker 4.", label="test.label", source="remote.ndjson"),
        ]

        kept = apply_rule_tier(
            rows,
            {"test.label"},
            {"en"},
            arguments,
            report,
            rejected,
            {holdout.lower()},
            {near_duplicate_signature(holdout)},
        )

        self.assertEqual([row.text for row in kept], ["Your parcel is ready at locker 4."])
        self.assertEqual(report.rejected["holdout-exact"], 1)
        self.assertEqual(report.rejected["holdout-near"], 1)

    def test_high_confidence_remote_disagreements_are_deterministically_downsampled(self):
        row = Row(
            text="No-review game loan requires an unlock fee before payout",
            label="spam",
            source="remote-training.ndjson",
            language="en",
            predicted_label="finance.bank",
            predicted_confidence=0.96,
            agreement=0,
            model_version="classic-v7",
        )
        report = Report()
        rejected: list[dict] = []
        arguments = SimpleNamespace(min_length=8, max_length=500, remote_disagreement_keep=0)

        kept = apply_rule_tier([row], {"spam", "finance.bank"}, {"en"}, arguments, report, rejected)

        self.assertEqual(kept, [])
        self.assertEqual(report.rejected["remote-disagreement-downsample"], 1)

    def test_inconsistent_remote_assessment_is_rejected(self):
        row = Row(
            text="Your account notice is available in the official app",
            label="finance.bank",
            source="remote-training.ndjson",
            language="en",
            predicted_label="finance.bank",
            predicted_confidence=0.9,
            agreement=0,
        )
        report = Report()
        rejected: list[dict] = []
        arguments = SimpleNamespace(min_length=8, max_length=500, remote_disagreement_keep=1)

        kept = apply_rule_tier([row], {"finance.bank"}, {"en"}, arguments, report, rejected)

        self.assertEqual(kept, [])
        self.assertEqual(report.rejected["invalid-assessment"], 1)

    def test_template_variants_are_cluster_deduplicated(self):
        report = Report()
        rejected: list[dict] = []
        arguments = SimpleNamespace(min_length=8, max_length=500, remote_disagreement_keep=1)
        rows = [
            Row(text="[Bank A] Loan 991122 approved. Visit https://a.example/x", label="finance.bank", source="a", language="en"),
            Row(text="[Bank B] Loan 448899 approved. Visit https://b.example/y", label="finance.bank", source="b", language="en"),
        ]

        kept = apply_rule_tier(rows, {"finance.bank"}, {"en"}, arguments, report, rejected)

        self.assertEqual(len(kept), 1)
        self.assertEqual(report.rejected["template-duplicate"], 1)


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
        phone_ja = rehydrate_placeholders("電話 {{PHONE}}", "ja", stable_rng("phone-ja"))
        id_ja = rehydrate_placeholders("個人番号 {{ID}}", "ja", stable_rng("id-ja"))
        self.assertIn("元", amount_zh)
        self.assertIn("$", amount_en)
        self.assertRegex(phone_ja, r"090-\d{4}-\d{4}")
        self.assertIn("000000000000", id_ja)

    def test_id_placeholder(self):
        result = rehydrate_placeholders("证件号 {{ID}}", "zh", stable_rng("id"))
        self.assertNotIn("{{ID}}", result)
        value = re.search(r"\d{18}", result).group(0)
        weights = (7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2)
        expected = "10X98765432"[sum(int(digit) * weight for digit, weight in zip(value[:17], weights)) % 11]
        self.assertNotEqual(value[-1], expected)

    def test_plate_placeholder_is_language_aware(self):
        zh = rehydrate_placeholders("车牌 {{PLATE}}", "zh", stable_rng("plate-zh"))
        en = rehydrate_placeholders("Plate {{PLATE}}", "en", stable_rng("plate-en"))
        ja = rehydrate_placeholders("車両番号 {{PLATE}}", "ja", stable_rng("plate-ja"))
        de = rehydrate_placeholders("Kennzeichen {{PLATE}}", "de", stable_rng("plate-de"))
        fr = rehydrate_placeholders("Plaque {{PLATE}}", "fr", stable_rng("plate-fr"))
        es = rehydrate_placeholders("Matrícula {{PLATE}}", "es", stable_rng("plate-es"))

        self.assertRegex(zh, r"(?:[京津沪渝冀豫云辽黑湘皖鲁新苏浙赣鄂桂甘晋蒙陕吉闽贵粤青藏川宁琼][A-Z][A-Z0-9]{5,6}|[A-Z]{2} \d{1,4}|\d{1,4})")
        self.assertRegex(en, r"[A-Z0-9 -]{5,12}")
        self.assertRegex(ja, r"(?:品川|練馬|横浜|大阪|神戸) \d{3} [ぁ-ん] \d{2}-\d{2}")
        self.assertRegex(de, r"(?:B|M|HH)-(?:AB|CD|EF) \d{1,4}")
        self.assertRegex(fr, r"[A-Z]{2}-\d{3}-[A-Z]{2}")
        self.assertRegex(es, r"\d{4} [A-Z]{3}")
        self.assertNotIn("{{PLATE}}", zh + en + ja + de + fr + es)


class NormalizeTests(unittest.TestCase):
    def test_whitespace_collapse(self):
        self.assertEqual(normalize("  a　\n b  "), "a b")


if __name__ == "__main__":
    unittest.main()
