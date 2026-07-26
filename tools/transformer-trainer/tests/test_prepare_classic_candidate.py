from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "tools/apple-trainer/Scripts/prepare_classic_candidate.py"


class PrepareClassicCandidateTests(unittest.TestCase):
    def test_supplement_cannot_add_cross_label_near_duplicate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            base = directory / "base.ndjson"
            supplement = directory / "supplement.ndjson"
            holdout = directory / "holdout.ndjson"
            output = directory / "candidate.ndjson"
            report = directory / "report.json"
            base.write_text(
                json.dumps({"text": "Account 123456 status was updated today", "label": "alpha"}) + "\n",
                encoding="utf-8",
            )
            supplement.write_text(
                json.dumps({"text": "Account 987654 status was updated today", "label": "beta"}) + "\n",
                encoding="utf-8",
            )
            holdout.write_text(
                json.dumps({"text": "Unrelated external evaluation message", "label": "alpha"}) + "\n",
                encoding="utf-8",
            )

            subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "--base",
                    str(base),
                    "--supplement",
                    str(supplement),
                    "--holdout",
                    str(holdout),
                    "--labels",
                    "beta",
                    "--out",
                    str(output),
                    "--report",
                    str(report),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            rows = [json.loads(line) for line in output.read_text(encoding="utf-8").splitlines()]
            summary = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(rows, [{"text": "Account 123456 status was updated today", "label": "alpha"}])
            self.assertEqual(summary["rejected"]["supplement:cross-label-near-conflict"], 1)

    def test_supplement_can_be_filtered_by_source_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            base = directory / "base.ndjson"
            supplement = directory / "supplement.ndjson"
            holdout = directory / "holdout.ndjson"
            output = directory / "candidate.ndjson"
            report = directory / "report.json"
            base.write_text(
                json.dumps({"text": "Existing base message", "label": "alpha"}) + "\n",
                encoding="utf-8",
            )
            supplement.write_text(
                "".join([
                    json.dumps({
                        "text": "Reviewed cloud expiry warning",
                        "label": "beta",
                        "source": "augmentation:boundary:cloud-expiry",
                    }) + "\n",
                    json.dumps({
                        "text": "Unrelated synthetic beta row",
                        "label": "beta",
                        "source": "synthetic:en",
                    }) + "\n",
                ]),
                encoding="utf-8",
            )
            holdout.write_text(
                json.dumps({"text": "External evaluation message", "label": "alpha"}) + "\n",
                encoding="utf-8",
            )

            subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "--base", str(base),
                    "--supplement", str(supplement),
                    "--holdout", str(holdout),
                    "--labels", "beta",
                    "--supplement-source-prefix", "augmentation:boundary:cloud-",
                    "--out", str(output),
                    "--report", str(report),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            rows = [json.loads(line) for line in output.read_text(encoding="utf-8").splitlines()]
            self.assertCountEqual(rows, [
                {"text": "Existing base message", "label": "alpha"},
                {"text": "Reviewed cloud expiry warning", "label": "beta"},
            ])


if __name__ == "__main__":
    unittest.main()
