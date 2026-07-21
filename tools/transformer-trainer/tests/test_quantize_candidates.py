from __future__ import annotations

import datetime
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from quantize_candidates import (
    candidate_build_identity,
    checkpoint_labels,
    combined_language_accuracy,
    model_smoke_failure,
    reusable_candidate,
    run_message_filter_artifact_suite,
    select_calibration_rows,
    taxonomy_actions,
    tokenizer_artifact_name,
    utc_timestamp,
)


class QuantizeCandidateTests(unittest.TestCase):
    def test_published_tokenizer_uses_public_model_name(self) -> None:
        self.assertEqual(
            tokenizer_artifact_name("SiftSignalModel"),
            "SiftSignalModel.tokenizer.siftbpe",
        )

    def test_utc_timestamp_is_nonempty_rfc3339(self) -> None:
        value = utc_timestamp()

        self.assertTrue(value.endswith("Z"))
        parsed = datetime.datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
        self.assertEqual(parsed.utcoffset(), datetime.timedelta(0))

    def test_language_accuracy_combines_fixed_and_promotion_counts(self) -> None:
        accuracy = combined_language_accuracy(
            {"languageCorrect": {"zh": 2, "en": 1}, "languageTotals": {"zh": 2, "en": 2}},
            {"languageCorrect": {"zh": 1, "en": 2}, "languageTotals": {"zh": 2, "en": 2}},
        )

        self.assertEqual(accuracy, {"en": 0.75, "zh": 0.75})

    def test_taxonomy_actions_inherits_group_action_and_allows_leaf_override(self) -> None:
        payload = {
            "groups": [
                {
                    "systemAction": "transaction",
                    "leaves": [
                        {"id": "finance.bank"},
                        {"id": "finance.promotion", "systemAction": "promotion"},
                    ],
                }
            ]
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            taxonomy = Path(temporary_directory) / "taxonomy.json"
            taxonomy.write_text(json.dumps(payload), encoding="utf-8")

            actions = taxonomy_actions(taxonomy)

        self.assertEqual(
            actions,
            {"finance.bank": "transaction", "finance.promotion": "promotion"},
        )

    def test_calibration_selection_round_robins_label_and_language_buckets(self) -> None:
        rows = [
            {"text": "第二条", "label": "a"},
            {"text": "English A", "label": "a"},
            {"text": "第一条", "label": "a"},
            {"text": "English B", "label": "b"},
            {"text": "お知らせ", "label": "b"},
        ]

        selected = select_calibration_rows(rows, 4)

        self.assertEqual(
            selected,
            [
                {"text": "English A", "label": "a"},
                {"text": "第二条", "label": "a"},
                {"text": "English B", "label": "b"},
                {"text": "お知らせ", "label": "b"},
            ],
        )

    def test_candidate_reuse_requires_an_exact_build_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            candidate = Path(temporary_directory)
            model = candidate / "model.mlpackage"
            model.mkdir()
            tokenizer = candidate / "tokenizer.siftbpe"
            tokenizer.write_bytes(b"tokenizer")
            identity = {"schemaVersion": 1, "sourceModelSHA256": "source-a"}
            (candidate / "candidate-build-identity.json").write_text(
                json.dumps(identity), encoding="utf-8"
            )

            self.assertTrue(reusable_candidate(candidate, model, tokenizer, identity))
            self.assertFalse(
                reusable_candidate(
                    candidate,
                    model,
                    tokenizer,
                    {"schemaVersion": 1, "sourceModelSHA256": "source-b"},
                )
            )

    def test_activation_candidate_identity_records_activation_then_weight_order(self) -> None:
        identity = candidate_build_identity(
            {
                "id": "w4a8-block16-ptq",
                "method": "ptq",
                "weightBits": 4,
                "activationBits": 8,
            },
            source_model_sha256="source",
            tokenizer_sha256="tokenizer",
            calibration={"required": True, "sampleSHA256": "samples"},
            max_length=96,
            coremltools_version="9.0",
        )

        self.assertEqual(identity["schemaVersion"], 2)
        self.assertEqual(identity["quantizationOrder"], "activation-then-weight")
        self.assertEqual(identity["coremltoolsVersion"], "9.0")

    def test_model_smoke_isolates_non_finite_candidate_failure(self) -> None:
        result = subprocess.CompletedProcess(
            args=[], returncode=3, stdout="non_finite_probabilities\n", stderr=""
        )
        with patch("quantize_candidates.subprocess.run", return_value=result) as run:
            failure = model_smoke_failure(Path("candidate.mlpackage"), 96)

        self.assertEqual(failure, "cpu_only_smoke_non_finite_probabilities_exit_3")
        self.assertEqual(run.call_count, 1)

    def test_model_smoke_requires_cpu_and_all_to_pass(self) -> None:
        result = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        with patch("quantize_candidates.subprocess.run", return_value=result) as run:
            failure = model_smoke_failure(Path("candidate.mlpackage"), 96)

        self.assertIsNone(failure)
        self.assertEqual(run.call_count, 2)

    def test_message_filter_artifact_suite_includes_readable_case_gate(self) -> None:
        result = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        with tempfile.TemporaryDirectory() as temporary_directory:
            candidate = Path(temporary_directory)
            (candidate / "message-filter-actions.json").write_text("{}", encoding="utf-8")
            with (
                patch("quantize_candidates.shutil.which", return_value="/usr/bin/swift"),
                patch("quantize_candidates.subprocess.run", return_value=result) as run,
            ):
                report = run_message_filter_artifact_suite(
                    candidate,
                    candidate / "model.mlpackage",
                    candidate / "tokenizer.siftbpe",
                    candidate / "manifest.json",
                    candidate / "fixed.ndjson",
                    candidate / "promotion.ndjson",
                    candidate / "conversation.ndjson",
                )

        self.assertEqual(report, {})
        command = run.call_args.args[0]
        self.assertIn("--readable-cases", command)
        self.assertIn("--conversation", command)

    def test_message_filter_artifact_suite_keeps_quality_failure_report(self) -> None:
        result = subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout="",
            stderr="MessageFilterArtifactTests failed: readableCaseGateFailed",
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            candidate = Path(temporary_directory)
            output = candidate / "message-filter-actions.json"
            output.write_text(json.dumps({"readableCases": [{"passed": False}]}), encoding="utf-8")
            with (
                patch("quantize_candidates.shutil.which", return_value="/usr/bin/swift"),
                patch("quantize_candidates.subprocess.run", return_value=result),
            ):
                report = run_message_filter_artifact_suite(
                    candidate,
                    candidate / "model.mlpackage",
                    candidate / "tokenizer.siftbpe",
                    candidate / "manifest.json",
                    candidate / "fixed.ndjson",
                    candidate / "promotion.ndjson",
                    candidate / "conversation.ndjson",
                )

        self.assertFalse(report["readableCases"][0]["passed"])
        self.assertIn("readableCaseGateFailed", report["suiteFailure"])

    def test_checkpoint_labels_follow_numeric_id_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            checkpoint = Path(temporary_directory)
            (checkpoint / "config.json").write_text(
                json.dumps({"id2label": {"1": "second", "0": "first"}}),
                encoding="utf-8",
            )

            labels = checkpoint_labels(checkpoint)

        self.assertEqual(labels, ["first", "second"])


if __name__ == "__main__":
    unittest.main()
