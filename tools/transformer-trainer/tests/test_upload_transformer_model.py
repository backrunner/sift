import hashlib
import base64
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from upload_transformer_model import (
    canonical_catalog_payload,
    canonical_channel_payload,
    canonical_release_payload,
    legacy_canonical_release_payload,
    entries_after_metadata_revision,
    make_channel_catalog,
    merge_channel_entries,
    normalize_manifest,
    normalize_reused_artifacts_base_url,
    pending_immutable_remote_items,
    sign_payload,
    UploadItem,
    verified_channel_entries,
    verify_selected_candidate,
    verify_http,
    verify_reused_remote_artifacts,
    validate_release_profile,
    release_signature_matches,
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
        report = self.valid_report("w8a32-channel-ptq", report_artifact_sha, 1234)
        report_path = root / "candidate.report.json"
        report_path.write_text(json.dumps(report), encoding="utf-8")
        selection = {
            "schemaVersion": 1,
            "profileID": "w8a32-channel-ptq",
            "artifactSHA256": "artifact-sha",
            "reportSHA256": hashlib.sha256(report_path.read_bytes()).hexdigest(),
            "reportPath": str(report_path),
        }
        selection_path = root / "selected-candidate.json"
        selection_path.write_text(json.dumps(selection), encoding="utf-8")
        manifest = {
            "sha256": "artifact-sha",
            "downloadBytes": 1234,
            "runtimeProfile": {"computePrecision": "float32"},
            "quantizationProfile": {
                "identifier": "w8a32-channel-ptq",
                "method": "ptq",
                "weightBits": 8,
                "activationBits": 32,
            },
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

    def test_normalize_manifest_uses_the_ios_v2_validation_metrics_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "SiftSignalModel.mlpackage"
            package.mkdir()
            (package / "model.mlmodel").write_bytes(b"model")
            tokenizer = root / "SiftSignalModel.tokenizer.siftbpe"
            tokenizer.write_bytes(b"compact")
            manifest = {
                "modelArtifact": package.name,
                "tokenizerKind": "bpe",
                "tokenizerArtifact": tokenizer.name,
                "quantizationProfile": {
                    "identifier": "w8a16-channel-ptq",
                    "weightBits": 8,
                    "activationBits": 16,
                    "method": "ptq",
                    "granularity": "per-channel",
                    "quantizationOrder": "weight-only",
                    "calibration": {"required": False},
                },
                "validationMetrics": {
                    "fixedAccuracy": 0.995,
                    "promotionAccuracy": 0.98,
                    "billingAccuracy": 0.95,
                    "conversationAccuracy": 1.0,
                    "fp16Agreement": 1.0,
                    "languageAccuracy": {"zh": 0.99, "en": 1.0, "ja": 0.985},
                },
            }

            normalized = normalize_manifest(
                manifest,
                root,
                "SiftSignalModel",
                "https://example.com/models/releases/signal-v3",
            )

            self.assertEqual(
                normalized["validationMetrics"],
                {
                    "fixedAccuracy": 0.995,
                    "promotionAccuracy": 0.98,
                    "fp16Agreement": 1,
                    "languageAccuracy": {"zh": 0.99, "en": 1, "ja": 0.985},
                },
            )
            self.assertIn("billingAccuracy", manifest["validationMetrics"])
            self.assertEqual(
                normalized["quantizationProfile"],
                {
                    "identifier": "w8a16-channel-ptq",
                    "weightBits": 8,
                    "activationBits": 16,
                    "method": "ptq",
                    "granularity": "per-channel",
                },
            )
            canonical = canonical_release_payload(normalized).decode("utf-8")
            self.assertNotIn("billingAccuracy", canonical)
            self.assertNotIn("conversationAccuracy", canonical)
            self.assertNotIn("calibration", canonical)
            self.assertNotIn("quantizationOrder", canonical)
            self.assertIn('"fp16Agreement":1', canonical)

    def test_upload_guard_accepts_sha_bound_selected_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            selection_path, manifest = self.selection_fixture(root)

            verify_selected_candidate(selection_path, manifest, root)

    def test_upload_guard_requires_a_bound_gate_for_distilled_student(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            selection_path, manifest = self.selection_fixture(root)
            selection = json.loads(selection_path.read_text(encoding="utf-8"))
            report_path = Path(selection["reportPath"])
            report = json.loads(report_path.read_text(encoding="utf-8"))
            distillation = {
                "teacherCheckpointSHA256": "a" * 64,
                "teacherLayers": 22,
                "studentLayers": 12,
                "temperature": 2.0,
                "distillAlpha": 0.7,
            }
            report.update({
                "algorithm": "teacher-student-distillation",
                "distillation": distillation,
            })
            report_path.write_text(json.dumps(report), encoding="utf-8")
            selection["reportSHA256"] = hashlib.sha256(report_path.read_bytes()).hexdigest()
            manifest.update({
                "algorithm": "teacher-student-distillation",
                "distillation": distillation,
            })
            selection.update({
                "teacherProfileID": "fp32-baseline",
                "teacherArtifactSHA256": "c" * 64,
                "teacherReportSHA256": "d" * 64,
            })
            selection_path.write_text(json.dumps(selection), encoding="utf-8")

            with self.assertRaisesRegex(SystemExit, "missing distillation gate"):
                verify_selected_candidate(selection_path, manifest, root)

            gate = {
                "schemaVersion": 1,
                "passed": True,
                "teacher": {
                    "profileID": "fp32-baseline",
                    "artifactSHA256": "c" * 64,
                    "reportSHA256": "d" * 64,
                },
                "student": {
                    "profileID": report["profileID"],
                    "artifactSHA256": report["artifactSHA256"],
                    "reportSHA256": selection["reportSHA256"],
                    "distillation": distillation,
                },
            }
            gate_path = root / "distillation-gate.json"
            gate_path.write_text(json.dumps(gate), encoding="utf-8")
            selection["distillationGatePath"] = str(gate_path)
            selection["distillationGateSHA256"] = hashlib.sha256(gate_path.read_bytes()).hexdigest()
            selection_path.write_text(json.dumps(selection), encoding="utf-8")
            verify_selected_candidate(selection_path, manifest, root)

    def test_upload_guard_rejects_gate_bound_to_a_different_teacher(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            selection_path, manifest = self.selection_fixture(root)
            selection = json.loads(selection_path.read_text(encoding="utf-8"))
            report_path = Path(selection["reportPath"])
            report = json.loads(report_path.read_text(encoding="utf-8"))
            distillation = {
                "teacherCheckpointSHA256": "a" * 64,
                "teacherLayers": 22,
                "studentLayers": 12,
                "temperature": 2.0,
                "distillAlpha": 0.7,
            }
            report.update({"algorithm": "teacher-student-distillation", "distillation": distillation})
            report_path.write_text(json.dumps(report), encoding="utf-8")
            selection.update({
                "reportSHA256": hashlib.sha256(report_path.read_bytes()).hexdigest(),
                "teacherProfileID": "fp32-baseline",
                "teacherArtifactSHA256": "c" * 64,
                "teacherReportSHA256": "d" * 64,
            })
            manifest.update({"algorithm": "teacher-student-distillation", "distillation": distillation})
            gate = {
                "schemaVersion": 1,
                "passed": True,
                "teacher": {
                    "profileID": "fp32-baseline",
                    "artifactSHA256": "different" * 8,
                    "reportSHA256": "d" * 64,
                },
                "student": {
                    "profileID": report["profileID"],
                    "artifactSHA256": report["artifactSHA256"],
                    "reportSHA256": selection["reportSHA256"],
                    "distillation": distillation,
                },
            }
            gate_path = root / "distillation-gate.json"
            gate_path.write_text(json.dumps(gate), encoding="utf-8")
            selection.update({
                "distillationGatePath": str(gate_path),
                "distillationGateSHA256": hashlib.sha256(gate_path.read_bytes()).hexdigest(),
            })
            selection_path.write_text(json.dumps(selection), encoding="utf-8")

            with self.assertRaisesRegex(SystemExit, "does not match current teacher"):
                verify_selected_candidate(selection_path, manifest, root)

    def test_release_canonical_payload_includes_distillation_and_legacy_excludes_it(self) -> None:
        manifest = {
            "schemaVersion": 2,
            "algorithm": "teacher-student-distillation",
            "distillation": {
                "teacherCheckpointSHA256": "a" * 64,
                "teacherLayers": 22,
                "studentLayers": 12,
                "temperature": 2.0,
                "distillAlpha": 0.7,
            },
        }
        self.assertIn(b'"distillation"', canonical_release_payload(manifest))
        self.assertNotIn(b'"distillation"', legacy_canonical_release_payload(manifest))

    def test_release_profile_rejects_fp32_graph_with_a16_metadata(self) -> None:
        with self.assertRaisesRegex(SystemExit, "use an A32 profile"):
            validate_release_profile({
                "runtimeProfile": {"computePrecision": "float32"},
                "quantizationProfile": {
                    "identifier": "w4a16-block16-ptq",
                    "method": "ptq",
                    "weightBits": 4,
                    "activationBits": 16,
                },
            })

        validate_release_profile({
            "runtimeProfile": {"computePrecision": "float32"},
            "quantizationProfile": {
                "identifier": "w4a32-block16-ptq",
                "method": "ptq",
                "weightBits": 4,
                "activationBits": 32,
            },
        })

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

    def test_immutable_remote_release_resumes_only_for_identical_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "artifact.bin"
            source.write_bytes(b"accepted model bytes")
            item = UploadItem(source, "releases/v16/artifact.bin", "application/octet-stream", "immutable")
            expected = (hashlib.sha256(source.read_bytes()).hexdigest(), source.stat().st_size)

            with patch("upload_transformer_model.public_object_digest", return_value=expected):
                self.assertEqual(pending_immutable_remote_items([item], "https://example.com/models"), [])

            with patch("upload_transformer_model.public_object_digest", return_value=("0" * 64, source.stat().st_size)):
                with self.assertRaisesRegex(SystemExit, "immutable model URL already contains different bytes"):
                    pending_immutable_remote_items([item], "https://example.com/models")

    def test_metadata_revision_requires_https_and_hash_validates_reused_artifacts(self) -> None:
        self.assertEqual(
            normalize_reused_artifacts_base_url("https://example.com/releases/v3/"),
            "https://example.com/releases/v3",
        )
        with self.assertRaisesRegex(SystemExit, "must use https"):
            normalize_reused_artifacts_base_url("http://example.com/releases/v3")

        manifest = {
            "remoteArtifacts": [{
                "path": "SiftSignalModel.mlpackage/Data/model.mlmodel",
                "sha256": "a" * 64,
                "byteCount": 12,
            }],
        }
        with patch("upload_transformer_model.public_object_digest", return_value=("a" * 64, 12)):
            verify_reused_remote_artifacts(manifest, "https://example.com/releases/v3")
        with patch("upload_transformer_model.public_object_digest", return_value=("b" * 64, 12)):
            with self.assertRaisesRegex(SystemExit, "does not match signed metadata"):
                verify_reused_remote_artifacts(manifest, "https://example.com/releases/v3")

    def test_metadata_revision_replaces_only_the_matching_compatibility_entry(self) -> None:
        release2 = {
            "modelABI": "sift-signal-v1",
            "releaseSequence": 2,
            "minimumAppBuild": 10,
            "maximumAppBuild": 15,
            "minimumOSVersion": "18.0",
            "downloadBytes": 100,
            "releaseID": "v2",
        }
        release3 = {**release2, "releaseSequence": 3, "minimumAppBuild": 16, "releaseID": "v3"}
        replacement = {**release2, "releaseID": "v2-metadata-v2"}

        self.assertEqual(entries_after_metadata_revision([release2, release3], replacement), [release3])
        with self.assertRaisesRegex(SystemExit, "cannot change release compatibility"):
            entries_after_metadata_revision([release2, release3], {**replacement, "minimumAppBuild": 11})
        with self.assertRaisesRegex(SystemExit, "exactly one published release"):
            entries_after_metadata_revision([release3], replacement)

    def test_public_verification_checks_full_bytes_and_size(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "channel.json"
            source.write_bytes(b'{"releaseSequence":3}')
            item = UploadItem(source, "channels/v2/channel.json", "application/json", "manifest")
            expected = (hashlib.sha256(source.read_bytes()).hexdigest(), source.stat().st_size)

            with patch("upload_transformer_model.public_object_digest", return_value=expected):
                verify_http([item], "https://example.com/models")

            with patch("upload_transformer_model.public_object_digest", return_value=(expected[0], expected[1] + 1)):
                with self.assertRaisesRegex(SystemExit, "public object bytes do not match upload"):
                    verify_http([item], "https://example.com/models")

    @unittest.skipUnless(shutil.which("openssl"), "OpenSSL is required for signing")
    def test_channel_catalog_keeps_legacy_pointer_and_binds_complete_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            private_key = Path(directory) / "test-ed25519.pem"
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "Ed25519", "-out", str(private_key)],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            def signed_entry(sequence: int, minimum_build: int, maximum_build: int) -> dict:
                entry = {
                    "schemaVersion": 2,
                    "releaseSequence": sequence,
                    "releaseID": f"signal-v{sequence}",
                    "releaseManifestURL": f"https://example.com/releases/v{sequence}/manifest.json",
                    "releaseManifestSHA256": str(sequence) * 64,
                    "modelABI": "sift-signal-v1",
                    "minimumAppBuild": minimum_build,
                    "maximumAppBuild": maximum_build,
                    "minimumOSVersion": "18.0",
                    "downloadBytes": 100,
                    "keyID": "test",
                }
                entry["signature"] = sign_payload(canonical_channel_payload(entry), private_key)
                return entry

            release2 = signed_entry(2, 10, 15)
            release3 = signed_entry(3, 16, 2**63 - 1)
            catalog = make_channel_catalog([release3, release2], "test", private_key)

            self.assertEqual(catalog["releaseSequence"], 2)
            self.assertEqual(
                [item["releaseSequence"] for item in catalog["compatibleReleases"]],
                [2, 3],
            )
            self.assertEqual(verified_channel_entries(catalog, private_key), [release2, release3])

            truncated = dict(catalog)
            truncated["compatibleReleases"] = [release2]
            self.assertNotEqual(
                canonical_catalog_payload(truncated),
                canonical_catalog_payload(catalog),
            )
            with self.assertRaisesRegex(SystemExit, "catalog signature is invalid"):
                verified_channel_entries(truncated, private_key)

    def test_channel_catalog_rejects_conflicting_sequence_reuse(self) -> None:
        first = {
            "schemaVersion": 2,
            "releaseSequence": 3,
            "releaseID": "signal-v3-a",
            "releaseManifestURL": "https://example.com/a.json",
            "releaseManifestSHA256": "a" * 64,
            "modelABI": "sift-signal-v1",
            "minimumAppBuild": 16,
            "maximumAppBuild": 100,
            "minimumOSVersion": "18.0",
            "downloadBytes": 100,
            "keyID": "test",
            "signature": "signature-a",
        }
        second = dict(first, releaseID="signal-v3-b", signature="signature-b")
        with self.assertRaisesRegex(SystemExit, "different releases"):
            merge_channel_entries([first, second])

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
