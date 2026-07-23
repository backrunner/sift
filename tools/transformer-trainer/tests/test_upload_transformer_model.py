import hashlib
import base64
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from upload_transformer_model import (
    canonical_channel_payload,
    canonical_release_payload,
    normalize_manifest,
    sign_payload,
    verify_selected_candidate,
)


class UploadTransformerModelTests(unittest.TestCase):
    def valid_report(self, profile_id: str, artifact_sha: str, download_bytes: int) -> dict:
        return {
            "profileID": profile_id,
            "artifactSHA256": artifact_sha,
            "downloadBytes": download_bytes,
            "metrics": {
                "fixedAccuracy": 0.995,
                "promotionAccuracy": 0.98,
                "billingAccuracy": 0.95,
                "billingActionAccuracy": 1.0,
                "fp16Top1Agreement": 0.99,
                "probabilitiesFinite": True,
                "probabilitySumsValid": True,
            },
            "messageFilterActions": {
                "fixedAccuracy": 0.995,
                "promotionAccuracy": 0.98,
                "billingAccuracy": 1.0,
                "benignOrTransactionToJunk": 0,
                "promotionFalsePositiveRate": 0.0,
                "scamJunkRecall": 1.0,
                "rulesOverrideRate": 1.0,
            },
            "deviceMetrics": {
                "runtimeExecutionVerified": True,
                "accelerationVerified": True,
                "peakPhysicalFootprintIncreaseBytes": 128 * 1024 * 1024,
                "averagePhysicalFootprintIncreaseBytes": 96 * 1024 * 1024,
                "p95LatencyMilliseconds": 50,
                "p99LatencyMilliseconds": 80,
                "extensionColdP95Milliseconds": 700,
                "extensionColdP99Milliseconds": 850,
                "extensionColdMaximumMilliseconds": 950,
                "extensionWarmP95Milliseconds": 120,
                "extensionWarmP99Milliseconds": 200,
                "contentionFallbackP99Milliseconds": 580,
                "jetsamCount": 0,
                "memoryDriftBytes": 8 * 1024 * 1024,
                "memoryDriftFraction": 0.05,
                "stressConditionsPassed": True,
            },
        }

    def selection_fixture(self, root: Path, *, report_artifact_sha: str = "artifact-sha") -> tuple[Path, dict]:
        report = self.valid_report("w8a16-channel-ptq", report_artifact_sha, 1234)
        report_path = root / "candidate.report.json"
        report_path.write_text(json.dumps(report), encoding="utf-8")
        selection = {
            "schemaVersion": 1,
            "profileID": "w8a16-channel-ptq",
            "artifactSHA256": "artifact-sha",
            "reportSHA256": hashlib.sha256(report_path.read_bytes()).hexdigest(),
            "reportPath": str(report_path),
        }
        selection_path = root / "selected-candidate.json"
        selection_path.write_text(json.dumps(selection), encoding="utf-8")
        manifest = {
            "sha256": "artifact-sha",
            "downloadBytes": 1234,
            "quantizationProfile": {"identifier": "w8a16-channel-ptq"},
        }
        return selection_path, manifest

    def test_rejects_tokenizer_missing_from_remote_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "SiftSignalModel.mlpackage"
            package.mkdir()
            (package / "model.mlmodel").write_bytes(b"model")
            (root / "SiftSignalModel.tokenizer.siftbpe").write_bytes(b"compact")
            (root / "SiftSignalModel.tokenizer.json").write_bytes(b"legacy")

            manifest = {
                "modelArtifact": package.name,
                "tokenizerKind": "bpe",
                "tokenizerArtifact": "SiftSignalModel.tokenizer.siftbpe",
                "remoteArtifacts": [{
                    "path": "SiftSignalModel.tokenizer.json",
                }],
            }

            with self.assertRaisesRegex(SystemExit, "tokenizerArtifact is missing"):
                normalize_manifest(
                    manifest,
                    root,
                    "SiftSignalModel",
                    "https://example.com/models",
                )

    def test_rejects_legacy_vocabulary_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = {
                "modelArtifact": "SiftSignalModel.mlpackage",
                "vocabularyArtifact": "SiftSignalModel.vocab.txt",
            }

            with self.assertRaisesRegex(SystemExit, "tokenizerArtifact"):
                normalize_manifest(
                    manifest,
                    root,
                    "SiftSignalModel",
                    "https://example.com/models",
                )

    def test_upload_guard_accepts_sha_bound_selected_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            selection_path, manifest = self.selection_fixture(root)

            verify_selected_candidate(selection_path, manifest, root)

    def test_upload_guard_rejects_report_for_different_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            selection_path, manifest = self.selection_fixture(root, report_artifact_sha="other-sha")

            with self.assertRaisesRegex(SystemExit, "report artifact does not match"):
                verify_selected_candidate(selection_path, manifest, root)

    def test_upload_guard_rejects_changed_report_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            selection_path, manifest = self.selection_fixture(root)
            selection = json.loads(selection_path.read_text(encoding="utf-8"))
            Path(selection["reportPath"]).write_text("{}", encoding="utf-8")

            with self.assertRaisesRegex(SystemExit, "report is missing or has changed"):
                verify_selected_candidate(selection_path, manifest, root)

    @unittest.skipUnless(shutil.which("openssl"), "OpenSSL is required for signing")
    def test_ed25519_signing_supports_macos_one_shot_input(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            private_key = Path(directory) / "test-ed25519.pem"
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "Ed25519", "-out", str(private_key)],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            signature = sign_payload(b"Sift manifest signing regression", private_key)

            self.assertGreater(len(signature), 80)

    @unittest.skipUnless(shutil.which("openssl"), "OpenSSL is required for signing")
    def test_manifest_v2_interop_fixture_verifies_with_openssl(self) -> None:
        fixture_path = Path(__file__).with_name("fixtures") / "manifest_v2_ed25519.json"
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        public_key = base64.b64decode(fixture["publicKeyBase64"])

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            public_der = root / "public.der"
            public_der.write_bytes(bytes.fromhex("302a300506032b6570032100") + public_key)
            for name, canonicalizer in (
                ("channel", canonical_channel_payload),
                ("release", canonical_release_payload),
            ):
                payload = root / f"{name}.payload"
                signature = root / f"{name}.signature"
                payload.write_bytes(canonicalizer(fixture[name]))
                signature.write_bytes(base64.b64decode(fixture[name]["signature"]))
                result = subprocess.run(
                    [
                        "openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(public_der),
                        "-keyform", "DER", "-rawin", "-in", str(payload), "-sigfile", str(signature),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))


if __name__ == "__main__":
    unittest.main()
