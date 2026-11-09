import hashlib
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sift_pipeline import reviewed_public_paths, require_holdout_isolation, signal_training_set


class ReviewedPackageTests(unittest.TestCase):
    def test_unreviewed_coarse_source_cannot_silently_return_to_signal_training(self):
        with tempfile.TemporaryDirectory() as directory:
            train = Path(directory) / "train.ndjson"
            train.write_text(json.dumps({"text": "A normal store offer", "label": "spam",
                "source": "huggingface:codesignal/sms-spam-collection"}) + "\n")
            with patch("sift_pipeline.TRAIN_SET", train):
                with self.assertRaisesRegex(SystemExit, "unreviewed coarse"):
                    signal_training_set(SimpleNamespace())

    def test_signal_package_pins_corpus_decisions_and_every_mandatory_holdout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            paths = [root / name for name in ("train.ndjson", "decisions.json", "holdout.ndjson")]
            for p in paths:
                p.write_text("{}\n")
            train, decisions, holdout = paths
            sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
            report = {"outputPath": str(train), "outputSHA256": sha(train),
                "reviewManifestPath": str(decisions), "manifestSHA256": sha(decisions),
                "holdouts": {str(holdout): sha(holdout)}}
            report_path = root / "corpus-review.json"
            report_path.write_text(json.dumps(report))
            args = SimpleNamespace(signal_review_directory=root)
            with patch("sift_pipeline.holdout_test_sets", return_value=[holdout]):
                self.assertEqual(signal_training_set(args), (train, (holdout,)))
                decisions.write_text('{"changed": true}\n')
                with self.assertRaisesRegex(SystemExit, "decisions changed"):
                    signal_training_set(args)
                report["manifestSHA256"] = sha(decisions)
                report["holdouts"] = {}
                report_path.write_text(json.dumps(report))
                with self.assertRaisesRegex(SystemExit, "omits mandatory"):
                    signal_training_set(args)

    def test_package_hashes_and_additional_holdouts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            for name in ["train.ndjson", "test.ndjson", "manifest.json", "private.ndjson"]:
                (root / name).write_text("{}\n")
            sha = lambda name: hashlib.sha256((root / name).read_bytes()).hexdigest()
            report = {"manifestPath": str(root / "manifest.json"), "manifestSHA256": sha("manifest.json"),
                      "trainSHA256": sha("train.ndjson"), "testSHA256": sha("test.ndjson")}
            (root / "import-report.json").write_text(json.dumps(report))
            args = SimpleNamespace(reviewed_public_directory=root, extra_holdout=[root / "private.ndjson"])
            train, holdouts = reviewed_public_paths(args)
            self.assertEqual(train, root / "train.ndjson")
            self.assertEqual(holdouts, (root / "test.ndjson", root / "private.ndjson"))
            (root / "test.ndjson").write_text("changed\n")
            with self.assertRaisesRegex(SystemExit, "dataset checksum"):
                reviewed_public_paths(args)

    def test_extra_holdout_excluded_even_without_public_package(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            text = "A new private service case with reference 741926 for isolation."
            train, holdout = root / "train.ndjson", root / "private.ndjson"
            train.write_text(json.dumps({"text": text.replace("741926", "482617")}) + "\n")
            holdout.write_text(json.dumps({"text": text}) + "\n")
            _, paths = reviewed_public_paths(SimpleNamespace(extra_holdout=[holdout]))
            self.assertEqual(paths, (holdout,))
            with self.assertRaisesRegex(SystemExit, "near collisions"):
                require_holdout_isolation(train, paths)


if __name__ == "__main__":
    unittest.main()
