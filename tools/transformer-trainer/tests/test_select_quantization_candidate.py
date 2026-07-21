from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from select_quantization_candidate import candidate_failures, has_quality_failure, load_profiles, select_candidate


def report(profile_id: str, *, footprint: int, download: int, latency: float, promotion: float = 0.98) -> dict:
    return {
        "profileID": profile_id,
        "artifactSHA256": f"sha-{profile_id}",
        "downloadBytes": download,
        "metrics": {
            "fixedAccuracy": 0.995,
            "promotionAccuracy": promotion,
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
            "conversationAccuracy": 1.0,
            "benignOrTransactionToJunk": 0,
            "promotionFalsePositiveRate": 0.0,
            "scamJunkRecall": 1.0,
            "rulesOverrideRate": 1.0,
        },
        "deviceMetrics": {
            "accelerationVerified": True,
            "peakPhysicalFootprintBytes": footprint,
            "a12P95LatencyMilliseconds": latency,
            "a12P99LatencyMilliseconds": min(latency * 1.5, 240),
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
            "currentDevice": {
                "accelerationVerified": True,
                "p95LatencyMilliseconds": max(latency * 0.5, 1),
                "p99LatencyMilliseconds": max(latency * 0.75, 1),
                "extensionColdP95Milliseconds": 500,
                "extensionColdP99Milliseconds": 700,
                "extensionColdMaximumMilliseconds": 800,
                "extensionWarmP95Milliseconds": 100,
                "extensionWarmP99Milliseconds": 160,
                "contentionFallbackP99Milliseconds": 500,
                "jetsamCount": 0,
                "memoryDriftBytes": 4 * 1024 * 1024,
                "memoryDriftFraction": 0.03,
                "stressConditionsPassed": True,
            },
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
            path.write_text("{}", encoding="utf-8")
            item["_reportPath"] = str(path)
        return reports

    def test_selects_lower_download_when_footprints_are_within_five_percent(self) -> None:
        baseline = report("fp16-baseline", footprint=200, download=300, latency=20)
        int8 = report("w8a16-channel-ptq", footprint=100, download=100, latency=10)
        int4 = report("w4a16-block16-ptq", footprint=104, download=55, latency=11)

        selected = select_candidate(self.profiles, self.attach_report_paths([baseline, int8, int4]))

        self.assertEqual(selected["profileID"], "w4a16-block16-ptq")
        self.assertEqual(selected["artifactSHA256"], "sha-w4a16-block16-ptq")

    def test_failed_int4_ptq_enables_its_qat_fallback(self) -> None:
        baseline = report("fp16-baseline", footprint=200, download=300, latency=20)
        int8 = report("w8a16-channel-ptq", footprint=110, download=100, latency=10)
        failed_ptq = report("w4a16-block16-ptq", footprint=80, download=50, latency=9, promotion=0.95)
        qat = report("w4a16-block16-qat", footprint=82, download=55, latency=9, promotion=0.98)

        selected = select_candidate(
            self.profiles,
            self.attach_report_paths([baseline, int8, failed_ptq, qat]),
        )

        self.assertEqual(selected["profileID"], "w4a16-block16-qat")
        self.assertIn("promotionAccuracy", selected["rejectedCandidates"]["w4a16-block16-ptq"])

    def test_rejects_candidate_without_accelerator_evidence(self) -> None:
        baseline = report("fp16-baseline", footprint=200, download=300, latency=20)
        candidate = report("w8a16-channel-ptq", footprint=100, download=100, latency=10)
        candidate = copy.deepcopy(candidate)
        candidate["deviceMetrics"]["accelerationVerified"] = False

        with self.assertRaisesRegex(SystemExit, "no int8/int4 candidate"):
            select_candidate(self.profiles, self.attach_report_paths([baseline, candidate]))

    def test_rejects_candidate_with_failed_readable_case(self) -> None:
        baseline = report("fp16-baseline", footprint=200, download=300, latency=20)
        candidate = report("w8a16-channel-ptq", footprint=100, download=100, latency=10)
        candidate["messageFilterActions"]["readableCases"][0]["passed"] = False

        failures = candidate_failures(candidate, baseline)

        self.assertIn("readableCases", failures)

    def test_missing_device_evidence_does_not_trigger_qat(self) -> None:
        baseline = report("fp16-baseline", footprint=200, download=300, latency=20)
        candidate = report("w4a16-block16-ptq", footprint=100, download=100, latency=10)
        candidate["deviceMetrics"]["accelerationVerified"] = False

        failures = candidate_failures(candidate, baseline)

        self.assertIn("accelerationVerified", failures)
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


if __name__ == "__main__":
    unittest.main()
