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
    ignores_experimental_cpu_smoke_failure,
    linear_quantizer_options,
    load_source_manifest,
    merge_source_manifest,
    model_smoke_failure,
    representative_smoke_samples,
    reusable_candidate,
    run_message_filter_artifact_suite,
    select_calibration_rows,
    taxonomy_actions,
    tokenizer_artifact_name,
    utc_timestamp,
)


class QuantizeCandidateTests(unittest.TestCase):
    def test_cpu_smoke_exception_never_applies_to_release_eligible_profile(self) -> None:
        self.assertTrue(
            ignores_experimental_cpu_smoke_failure(
                {"eligibleForRelease": False},
                True,
                "cpu_only_smoke_non_finite_probabilities_exit_3",
            )
        )
        self.assertFalse(
            ignores_experimental_cpu_smoke_failure(
                {"eligibleForRelease": True},
                True,
                "cpu_only_smoke_non_finite_probabilities_exit_3",
            )
        )
        self.assertTrue(
            ignores_experimental_cpu_smoke_failure(
                {"eligibleForRelease": True},
                True,
                "cpu_only_smoke_non_finite_probabilities_exit_3",
                release_ineligible_run=True,
            )
        )

    def test_mixed_precision_override_uses_int4_block_quantization(self) -> None:
        options = linear_quantizer_options(
            {
                "weightBits": 4,
                "granularity": "per-block",
                "blockSize": 16,
            }
        )

        self.assertEqual(
            options,
            {
                "mode": "linear_symmetric",
                "dtype": "int4",
                "granularity": "per_block",
                "block_size": 16,
            },
        )

    def test_embedding_mixed_precision_profile_is_explicit_only(self) -> None:
        profiles = json.loads(
            (Path(__file__).parents[1] / "quantization-profiles.json").read_text(encoding="utf-8")
        )["profiles"]
        profile = next(
            item for item in profiles
            if item["id"] == "w8a16-channel-embedding-w4-block16-ptq"
        )

        self.assertFalse(profile["eligibleForRelease"])
        self.assertFalse(profile["enabledByDefault"])
        self.assertEqual(profile["weightOverrides"][0]["role"], "tokenEmbedding")

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

        self.assertEqual(identity["schemaVersion"], 3)
        self.assertEqual(identity["quantizationOrder"], "activation-then-weight")
        self.assertEqual(identity["coremltoolsVersion"], "9.0")

    def test_source_manifest_preserves_distillation_provenance(self) -> None:
        source = {
            "trainedAt": "2026-08-18T19:57:34.783Z",
            "algorithm": "teacher-student-distillation",
            "backbone": "jhu-clsp/mmBERT-small",
            "distillation": {
                "teacherCheckpointSHA256": "a" * 64,
                "teacherLayers": 22,
                "studentLayers": 12,
                "temperature": 2.0,
                "distillAlpha": 0.7,
            },
            "validationMetrics": {
                "validationAccuracy": 0.994,
                "teacherValidationAccuracy": 0.992,
            },
            "signature": "stale",
        }

        merged = merge_source_manifest(
            source,
            quantized_fields={"quantizedAt": "2026-08-19T00:00:00.000Z"},
            external_validation_metrics={"fixedAccuracy": 0.99},
        )

        self.assertEqual(merged["algorithm"], "teacher-student-distillation")
        self.assertEqual(merged["distillation"]["studentLayers"], 12)
        self.assertEqual(merged["trainedAt"], source["trainedAt"])
        self.assertEqual(merged["validationMetrics"]["teacherValidationAccuracy"], 0.992)
        self.assertEqual(merged["validationMetrics"]["fixedAccuracy"], 0.99)
        self.assertNotIn("signature", merged)

    def test_source_manifest_contract_requires_exact_model_identity(self) -> None:
        labels = ["__sift_abstain__", "travel.ticketing"]
        payload = {
            "schemaVersion": 2,
            "sha256": "model-sha",
            "modelArtifact": "SiftSignalModel.mlpackage",
            "tokenizerSHA256": "tokenizer-sha",
            "tokenizerArtifact": "SiftSignalModel.tokenizer.siftbpe",
            "taxonomyHash": "taxonomy-sha",
            "labels": labels,
            "maxSequenceLength": 96,
            "modelABI": "sift-signal-v1",
            "version": "signal-distilled",
            "quantizationProfile": {"weightBits": 16, "activationBits": 16},
            "algorithm": "teacher-student-distillation",
            "trainedAt": "2026-08-18T19:57:34.783Z",
            "backbone": "jhu-clsp/mmBERT-small",
            "tokenizerKind": "bpe",
            "languages": ["zh", "en", "ja"],
            "distillation": {
                "teacherCheckpointSHA256": "a" * 64,
                "teacherLayers": 22,
                "studentLayers": 12,
                "temperature": 2.0,
                "distillAlpha": 0.7,
            },
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            manifest = Path(temporary_directory) / "source.manifest.json"
            manifest.write_text(json.dumps(payload), encoding="utf-8")

            loaded = load_source_manifest(
                manifest,
                source_model_sha256="model-sha",
                source_model_name="SiftSignalModel.mlpackage",
                tokenizer_sha256="tokenizer-sha",
                tokenizer_name="SiftSignalModel.tokenizer.siftbpe",
                taxonomy_sha256="taxonomy-sha",
                labels=labels,
                max_length=96,
                model_abi="sift-signal-v1",
                version="signal-distilled",
            )
            self.assertEqual(loaded["distillation"]["teacherLayers"], 22)

            with self.assertRaisesRegex(SystemExit, "source manifest contract mismatch"):
                load_source_manifest(
                    manifest,
                    source_model_sha256="different-model-sha",
                    source_model_name="SiftSignalModel.mlpackage",
                    tokenizer_sha256="tokenizer-sha",
                    tokenizer_name="SiftSignalModel.tokenizer.siftbpe",
                    taxonomy_sha256="taxonomy-sha",
                    labels=labels,
                    max_length=96,
                    model_abi="sift-signal-v1",
                    version="signal-distilled",
                )

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

    def test_model_smoke_can_isolate_all_compute_units(self) -> None:
        result = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        with patch("quantize_candidates.subprocess.run", return_value=result) as run:
            failure = model_smoke_failure(
                Path("candidate.mlpackage"),
                96,
                compute_units=("ALL",),
            )

        self.assertIsNone(failure)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][-1], "ALL")

    def test_model_smoke_passes_encoded_samples_to_isolated_worker(self) -> None:
        result = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        samples = [{"input_ids": [[2, 1]], "attention_mask": [[1, 1]]}]
        with patch("quantize_candidates.subprocess.run", return_value=result) as run:
            failure = model_smoke_failure(
                Path("candidate.mlpackage"),
                2,
                compute_units=("ALL",),
                encoded_samples=samples,
            )

        self.assertIsNone(failure)
        self.assertEqual(json.loads(run.call_args.args[0][-1]), samples)

    def test_representative_smoke_samples_are_json_serializable(self) -> None:
        class Tokenizer:
            def __call__(self, text, **_):
                token = len(text)
                return {
                    "input_ids": [2, token, 1, 0],
                    "attention_mask": [1, 1, 1, 0],
                }

        samples = representative_smoke_samples(Tokenizer(), 4)

        self.assertEqual(len(samples), 3)
        self.assertEqual(samples[0]["input_ids"][0][0], 2)
        json.dumps(samples)

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
                    candidate / "billing.ndjson",
                    candidate / "conversation.ndjson",
                )

        self.assertEqual(report, {})
        command = run.call_args.args[0]
        self.assertIn("--readable-cases", command)
        self.assertIn("--conversation", command)
        self.assertIn("--billing", command)

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
                    candidate / "billing.ndjson",
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
