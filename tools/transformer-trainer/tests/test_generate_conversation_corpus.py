from __future__ import annotations

import json
import tempfile
import unittest
from collections import Counter
from pathlib import Path

from curate_dataset import near_duplicate_signature
from generate_conversation_corpus import generate_rows
from model_contract import ABSTAIN_LABEL


class GenerateConversationCorpusTests(unittest.TestCase):
    def test_generation_is_balanced_deterministic_and_holdout_isolated(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            holdout = Path(temporary_directory) / "holdout.ndjson"
            holdout_rows = [
                {"text": "我已经到地铁站了，晚饭想吃什么？我顺路带回来。"},
                {"text": "I am outside the library now. Should I wait here?"},
                {"text": "駅に着いたよ。改札の前で待っているね。"},
            ]
            holdout.write_text(
                "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in holdout_rows),
                encoding="utf-8",
            )

            first = generate_rows(20, 42, holdout)
            second = generate_rows(20, 42, holdout)

        self.assertEqual(first, second)
        self.assertEqual(Counter(row["language"] for row in first), {"zh": 20, "en": 20, "ja": 20})
        self.assertEqual({row["label"] for row in first}, {ABSTAIN_LABEL})
        holdout_near = {near_duplicate_signature(row["text"]) for row in holdout_rows}
        self.assertFalse({near_duplicate_signature(row["text"]) for row in first} & holdout_near)

    def test_generation_covers_weather_and_home_cooking_boundaries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            holdout = Path(temporary_directory) / "holdout.ndjson"
            holdout.write_text("", encoding="utf-8")
            rows = generate_rows(220, 42, holdout)

        by_language = {
            language: [row["text"] for row in rows if row["language"] == language]
            for language in ("zh", "en", "ja")
        }
        self.assertTrue(any("雨" in text and "到" in text for text in by_language["zh"]))
        self.assertTrue(any("rain" in text.lower() and "arrive" in text.lower() for text in by_language["en"]))
        self.assertTrue(any("雨" in text and "着" in text for text in by_language["ja"]))
        self.assertTrue(any("做多了" in text for text in by_language["zh"]))
        self.assertTrue(any("made too much" in text for text in by_language["en"]))
        self.assertTrue(any("作りすぎた" in text for text in by_language["ja"]))
        self.assertTrue(any("窗边" in text and "坐下" in text for text in by_language["zh"]))
        self.assertTrue(any("window" in text.lower() and "seat" in text.lower() for text in by_language["en"]))
        self.assertTrue(any("窓際" in text and "座" in text for text in by_language["ja"]))
        self.assertTrue(any("外套" in text and "下次" in text for text in by_language["zh"]))
        self.assertTrue(any("jacket" in text.lower() and "meet again" in text.lower() for text in by_language["en"]))
        self.assertTrue(any("上着" in text and "次に会う" in text for text in by_language["ja"]))


if __name__ == "__main__":
    unittest.main()
