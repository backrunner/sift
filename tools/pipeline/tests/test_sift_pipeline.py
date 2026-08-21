import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import sift_pipeline as pipeline  # noqa: E402


class HoldoutIsolationTests(unittest.TestCase):
    def test_transformer_defaults_preserve_full_release_model(self) -> None:
        with patch.object(sys, "argv", ["sift_pipeline.py", "train-transformer"]):
            arguments = pipeline.parse_arguments()

        self.assertEqual(arguments.truncate_layers, 0)
        self.assertEqual(arguments.max_sequence_length, 96)
        self.assertEqual(arguments.version_classic, "maxent-generalization-v50-seed29-r32")
        self.assertEqual(arguments.version_transformer, "signal-v4-generalization-v50-r32-distilled-12l")
        self.assertEqual(arguments.release_sequence, 4)
        self.assertEqual(arguments.minimum_app_build, 19)
        self.assertEqual(arguments.distillation_gate, [])

    def test_select_transformer_forwards_explicit_distillation_gates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reports = root / "transformer-model" / "quantization-tournament" / "reports"
            reports.mkdir(parents=True)
            gate = root / "gate.json"
            gate.write_text("{}", encoding="utf-8")
            with (
                patch.object(sys, "argv", ["sift_pipeline.py", "select-transformer", "--distillation-gate", str(gate)]),
                patch.object(pipeline, "TRANSFORMER_OUT", root / "transformer-model"),
                patch.object(pipeline, "TRANSFORMER_TRAINER", root / "trainer"),
                patch.object(pipeline, "require_tool"),
                patch.object(pipeline, "run") as run,
            ):
                arguments = pipeline.parse_arguments()
                pipeline.stage_select_transformer(arguments)

            command = run.call_args.args[0]
            self.assertIn("--distillation-gate", command)
            self.assertIn(str(gate.resolve()), command)

    def test_training_guard_rejects_exact_and_digit_normalized_collisions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixed = root / "fixed.ndjson"
            promotion = root / "promotion.ndjson"
            training = root / "training.ndjson"
            self.write_rows(fixed, ["Your verification code is 123456 and expires soon."])
            self.write_rows(promotion, ["Weekend sale saves 20 percent on groceries."])

            original_fixed = pipeline.CLASSIFICATION_TEST_SET
            original_promotion = pipeline.PROMOTION_TEST_SET
            pipeline.CLASSIFICATION_TEST_SET = fixed
            pipeline.PROMOTION_TEST_SET = promotion
            try:
                self.write_rows(training, [
                    "Your verification code is 123456 and expires soon.",
                    "Your verification code is 987654 and expires soon.",
                ])
                with self.assertRaisesRegex(SystemExit, "1 exact and 1 near"):
                    pipeline.require_holdout_isolation(training)

                self.write_rows(training, ["Your parcel is ready at locker 4."])
                pipeline.require_holdout_isolation(training)
            finally:
                pipeline.CLASSIFICATION_TEST_SET = original_fixed
                pipeline.PROMOTION_TEST_SET = original_promotion

    def test_distillation_refreshes_implicit_teacher_from_current_checkpoint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transformer_out = root / "transformer-model"
            source_checkpoint = transformer_out / "checkpoint"
            teacher_checkpoint = transformer_out / "teacher-checkpoint"
            training_set = root / "train.ndjson"
            source_checkpoint.mkdir(parents=True)
            teacher_checkpoint.mkdir(parents=True)
            (source_checkpoint / "current.txt").write_text("current", encoding="utf-8")
            (source_checkpoint / "config.json").write_text(json.dumps({"num_hidden_layers": 22}), encoding="utf-8")
            (teacher_checkpoint / "stale.txt").write_text("stale", encoding="utf-8")
            self.write_rows(training_set, ["Current leak-free row"])

            with (
                patch.object(sys, "argv", ["sift_pipeline.py", "distill-transformer"]),
                patch.object(pipeline, "TRANSFORMER_OUT", transformer_out),
                patch.object(pipeline, "TRAIN_SET", training_set),
                patch.object(pipeline, "require_tool"),
                patch.object(pipeline, "run") as run,
            ):
                arguments = pipeline.parse_arguments()
                pipeline.stage_distill_transformer(arguments)

            self.assertEqual((teacher_checkpoint / "current.txt").read_text(encoding="utf-8"), "current")
            self.assertFalse((teacher_checkpoint / "stale.txt").exists())
            command = run.call_args.args[0]
            teacher_index = command.index("--teacher-checkpoint") + 1
            self.assertEqual(command[teacher_index], str(teacher_checkpoint))

    @staticmethod
    def write_rows(path: Path, texts: list[str]) -> None:
        payload = "\n".join(json.dumps({"text": text, "label": "test"}) for text in texts)
        path.write_text(payload + "\n", encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
