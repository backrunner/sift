import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from upload_transformer_model import normalize_manifest


class UploadTransformerModelTests(unittest.TestCase):
    def test_rejects_tokenizer_missing_from_remote_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "SiftTransformerClassifier.mlpackage"
            package.mkdir()
            (package / "model.mlmodel").write_bytes(b"model")
            (root / "SiftTransformerClassifier.tokenizer.siftbpe").write_bytes(b"compact")
            (root / "SiftTransformerClassifier.tokenizer.json").write_bytes(b"legacy")

            manifest = {
                "modelArtifact": package.name,
                "tokenizerKind": "bpe",
                "tokenizerArtifact": "SiftTransformerClassifier.tokenizer.siftbpe",
                "remoteArtifacts": [{
                    "path": "SiftTransformerClassifier.tokenizer.json",
                }],
            }

            with self.assertRaisesRegex(SystemExit, "tokenizerArtifact is missing"):
                normalize_manifest(
                    manifest,
                    root,
                    "SiftTransformerClassifier",
                    "https://example.com/models",
                )

    def test_rejects_legacy_vocabulary_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = {
                "modelArtifact": "SiftTransformerClassifier.mlpackage",
                "vocabularyArtifact": "SiftTransformerClassifier.vocab.txt",
            }

            with self.assertRaisesRegex(SystemExit, "tokenizerArtifact"):
                normalize_manifest(
                    manifest,
                    root,
                    "SiftTransformerClassifier",
                    "https://example.com/models",
                )


if __name__ == "__main__":
    unittest.main()
