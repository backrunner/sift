from __future__ import annotations

import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from check_distillation_gate import compare_reports, make_gate_report
from select_quantization_candidate import (
    candidate_failures,
    has_quality_failure,
    load_distillation_gates,
    load_profiles,
    select_candidate,
)


def report(
    profile_id: str,
    *,
    footprint: int,
    download: int,
    latency: float,
    cold_latency: float = 700,
    promotion: float = 0.98,
) -> dict:
    return {
        "profileID": profile_id,
        "artifactSHA256": f"sha-{profile_id}",
        "downloadBytes": download,
        "metrics": {
            "fixedAccuracy": 0.995,
            "promotionAccuracy": promotion,
            "billingAccuracy": 0.95,
            "billingActionAccuracy": 1.0,
            "conversationAccuracy": 1.0,
            "conversationActionAccuracy": 1.0,
            "fp16Top1Agreement": 0.99,
            "probabilitiesFinite": True,
            "probabilitySumsValid": True,
            "languageAccuracy": {"zh": 0.99, "en": 0.99, "ja": 0.99},
        },
        "messageFilterActions": {
            "readableCaseSuiteVersion": 2,
            "readableCaseCount": 17,
            "readableCases": [{"passed": True} for _ in range(17)],
            "fixedAccuracy": 0.995,
            "promotionAccuracy": 0.98,
            "billingAccuracy": 1.0,
            "conversationAccuracy": 1.0,
            "benignOrTransactionToJunk": 0,
            "promotionFalsePositiveRate": 0.0,
            "scamJunkRecall": 1.0,
            "rulesOverrideRate": 1.0,
        },
        "deviceMetrics": {
            "runtimeExecutionVerified": True,
            "accelerationVerified": True,
            "computeUnits": "all",
            "peakPhysicalFootprintBytes": footprint,
            "peakPhysicalFootprintIncreaseBytes": footprint,
            "averagePhysicalFootprintIncreaseBytes": footprint,
            "p95LatencyMilliseconds": latency,
            "p99LatencyMilliseconds": min(latency * 1.5, 240),
            "extensionColdP95Milliseconds": cold_latency,
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


class QuantizationCandidateSelectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.profiles = load_profiles(Path(__file__).parents[1] / "quantization-profiles.json")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def attach_report_paths(self, reports: list[dict]) -> list[dict]:
        root = Path(self.temp.name)
        for item in reports:
            path = root / f"{item['profileID']}.report.json"
            item["_reportPath"] = str(path)
            payload = {key: value for key, value in item.items() if not key.startswith("_")}
            path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
        return reports

    def distilled(self, profile_id: str, *, artifact: str | None = None) -> dict:
        candidate = report(profile_id, footprint=100, download=100, latency=10)
        candidate["algorithm"] = "teacher-student-distillation"
        candidate["distillation"] = {
            "teacherCheckpointSHA256": "a" * 64,
            "teacherLayers": 22,
            "studentLayers": 12,
            "temperature": 2.0,
            "distillAlpha": 0.7,
        }
        if artifact is not None:
            candidate["artifactSHA256"] = artifact
        return candidate

    def write_gate(self, teacher: dict, student: dict) -> Path:
        teacher_path = Path(teacher["_reportPath"])
        student_path = Path(student["_reportPath"])
        gate = make_gate_report(
            teacher,
            student,
            compare_reports(teacher, student),
            teacher_report_path=teacher_path,
            student_report_path=student_path,
        )
        gate_path = Path(self.temp.name) / "distillation-gate.json"
        gate_path.write_text(json.dumps(gate, sort_keys=True), encoding="utf-8")
        return gate_path

    def test_selects_lower_download_when_footprints_are_within_five_percent(self) -> None:
        baseline = report("fp32-baseline", footprint=200, download=300, latency=20)
        int8 = report("w8a32-channel-ptq", footprint=100, download=100, latency=10)
        int4 = report("w4a32-block16-ptq", footprint=104, download=55, latency=11)

        selected = select_candidate(self.profiles, self.attach_report_paths([baseline, int8, int4]))

        self.assertEqual(selected["profileID"], "w4a32-block16-ptq")
        self.assertEqual(selected["artifactSHA256"], "sha-w4a32-block16-ptq")

    def test_failed_int4_ptq_enables_its_qat_fallback(self) -> None:
        baseline = report("fp32-baseline", footprint=200, download=300, latency=20)
        int8 = report("w8a32-channel-ptq", footprint=110, download=100, latency=10)
        failed_ptq = report("w4a32-block16-ptq", footprint=80, download=50, latency=9, promotion=0.95)
        qat = report("w4a32-block16-qat", footprint=82, download=55, latency=9, promotion=0.98)

        selected = select_candidate(
            self.profiles,
            self.attach_report_paths([baseline, int8, failed_ptq, qat]),
        )

        self.assertEqual(selected["profileID"], "w4a32-block16-qat")
        self.assertIn("promotionAccuracy", selected["rejectedCandidates"]["w4a32-block16-ptq"])

    def test_prefers_faster_cold_start_when_size_and_memory_are_equivalent(self) -> None:
        baseline = report("fp32-baseline", footprint=200, download=300, latency=20)
        int8 = report(
            "w8a32-channel-ptq",
            footprint=100,
            download=100,
            latency=10,
            cold_latency=600,
        )
        int4 = report(
            "w4a32-block16-ptq",
            footprint=100,
            download=100,
            latency=10,
            cold_latency=700,
        )

        selected = select_candidate(self.profiles, self.attach_report_paths([baseline, int8, int4]))

        self.assertEqual(selected["profileID"], "w8a32-channel-ptq")

    def test_promotion_gate_requires_at_least_ninety_eight_percent(self) -> None:
        baseline = report("fp32-baseline", footprint=200, download=300, latency=20)
        candidate = report("w8a32-channel-ptq", footprint=100, download=100, latency=10, promotion=0.979)

        failures = candidate_failures(candidate, baseline)

        self.assertIn("promotionAccuracy", failures)

    def test_release_ineligible_experiment_cannot_be_selected(self) -> None:
        baseline = report("fp32-baseline", footprint=200, download=300, latency=20)
        candidate = report("w8a32-channel-ptq", footprint=100, download=100, latency=10)
        candidate["releaseEligible"] = False

        failures = candidate_failures(candidate, baseline)

        self.assertIn("releaseEligible", failures)

    def test_billing_gate_rejects_a_boundary_regression(self) -> None:
        baseline = report("fp32-baseline", footprint=200, download=300, latency=20)
        candidate = report("w8a32-channel-ptq", footprint=100, download=100, latency=10)
        candidate["metrics"]["billingAccuracy"] = 0.899

        failures = candidate_failures(candidate, baseline)

        self.assertIn("billingAccuracy", failures)

    def test_rejects_candidate_without_matching_runtime_evidence(self) -> None:
        baseline = report("fp32-baseline", footprint=200, download=300, latency=20)
        candidate = report("w8a32-channel-ptq", footprint=100, download=100, latency=10)
        candidate = copy.deepcopy(candidate)
        candidate["deviceMetrics"]["runtimeExecutionVerified"] = False

        with self.assertRaisesRegex(SystemExit, "no int8/int4 candidate"):
            select_candidate(self.profiles, self.attach_report_paths([baseline, candidate]))

    def test_rejects_candidate_with_failed_readable_case(self) -> None:
        baseline = report("fp32-baseline", footprint=200, download=300, latency=20)
        candidate = report("w8a32-channel-ptq", footprint=100, download=100, latency=10)
        candidate["messageFilterActions"]["readableCases"][0]["passed"] = False

        failures = candidate_failures(candidate, baseline)

        self.assertIn("readableCases", failures)

    def test_missing_device_evidence_does_not_trigger_qat(self) -> None:
        baseline = report("fp32-baseline", footprint=200, download=300, latency=20)
        candidate = report("w4a32-block16-ptq", footprint=100, download=100, latency=10)
        candidate["deviceMetrics"]["runtimeExecutionVerified"] = False

        failures = candidate_failures(candidate, baseline)

        self.assertIn("runtimeExecutionVerified", failures)
        self.assertFalse(has_quality_failure(failures))

    def test_every_w4_ptq_fallback_has_the_same_quantization_shape(self) -> None:
        for profile in self.profiles.values():
            fallback_id = profile.get("qatFallback")
            if profile.get("weightBits") != 4 or fallback_id is None:
                continue
            fallback = self.profiles[fallback_id]
            self.assertEqual(fallback["method"], "qat")
            self.assertEqual(fallback["weightBits"], profile["weightBits"])
            self.assertEqual(fallback["activationBits"], profile["activationBits"])
            self.assertEqual(fallback["blockSize"], profile["blockSize"])

    def test_distilled_candidate_requires_a_bound_passing_gate(self) -> None:
        baseline = report("fp32-baseline", footprint=200, download=300, latency=20)
        candidate = self.distilled("w4a32-block16-ptq")
        reports = self.attach_report_paths([baseline, candidate])
        with self.assertRaisesRegex(SystemExit, "no int8/int4 candidate"):
            select_candidate(self.profiles, reports)

        gate_path = self.write_gate(baseline, candidate)
        selection = select_candidate(
            self.profiles,
            reports,
            load_distillation_gates([gate_path]),
        )
        self.assertEqual(selection["profileID"], "w4a32-block16-ptq")
        self.assertEqual(selection["distillationGateSHA256"], hashlib.sha256(gate_path.read_bytes()).hexdigest())
        self.assertEqual(selection["teacherProfileID"], "fp32-baseline")
        self.assertEqual(selection["teacherArtifactSHA256"], baseline["artifactSHA256"])
        self.assertEqual(
            selection["teacherReportSHA256"],
            hashlib.sha256(Path(baseline["_reportPath"]).read_bytes()).hexdigest(),
        )

    def test_distilled_candidate_rejects_gate_for_a_different_teacher(self) -> None:
        baseline = report("fp32-baseline", footprint=200, download=300, latency=20)
        candidate = self.distilled("w4a32-block16-ptq")
        reports = self.attach_report_paths([baseline, candidate])
        gate_path = self.write_gate(baseline, candidate)
        gate = json.loads(gate_path.read_text(encoding="utf-8"))
        gate["teacher"]["artifactSHA256"] = "z" * 64
        gate_path.write_text(json.dumps(gate, sort_keys=True), encoding="utf-8")

        with self.assertRaisesRegex(SystemExit, "no int8/int4 candidate"):
            select_candidate(self.profiles, reports, load_distillation_gates([gate_path]))

    def test_failed_distillation_gate_cannot_select_student(self) -> None:
        baseline = report("fp32-baseline", footprint=200, download=300, latency=20)
        candidate = self.distilled("w4a32-block16-ptq")
        reports = self.attach_report_paths([baseline, candidate])
        gate_path = self.write_gate(baseline, candidate)
        gate = json.loads(gate_path.read_text(encoding="utf-8"))
        gate["passed"] = False
        gate_path.write_text(json.dumps(gate, sort_keys=True), encoding="utf-8")
        with self.assertRaisesRegex(SystemExit, "no int8/int4 candidate"):
            select_candidate(self.profiles, reports, load_distillation_gates([gate_path]))


if __name__ == "__main__":
    unittest.main()
