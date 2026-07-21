from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "export_message_filter_evidence.py"
SPEC = importlib.util.spec_from_file_location("export_message_filter_evidence", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def snapshot(*, at_least_one_second: int = 0) -> dict:
    identity = {
        "variant": "transformer",
        "modelABI": "sift-mmbert-v2",
        "releaseSequence": 9,
        "sha256": "a" * 64,
    }
    release = {
        "requestedArtifactIdentity": identity,
        "coldRunCount": 30,
        "warmQueryCount": 10_000,
        "coldLatencyBuckets": {
            "under750Milliseconds": 30 - at_least_one_second,
            "atLeast1000Milliseconds": at_least_one_second,
        },
        "warmLatencyBuckets": {"under150Milliseconds": 10_000},
        "firstPhysicalFootprintBytes": 100_000_000,
        "latestPhysicalFootprintBytes": 108_000_000,
        "peakPhysicalFootprintBytes": 120_000_000,
        "watchdogCount": 0,
        "fallbackCounts": {"none": 10_030},
        "errorCounts": {},
    }
    return {"schemaVersion": 1, "releases": {"release": release}}


class ExportMessageFilterEvidenceTests(unittest.TestCase):
    def test_builds_conservative_release_evidence(self) -> None:
        evidence = MODULE.build_evidence(
            snapshot(),
            9,
            device_model="iPhone11,8",
            os_version="18.6",
            trace_count=42,
            jetsam_count=0,
            contention_fallback_p99=590,
            gpu_contention_passed=True,
            low_power_passed=True,
            memory_pressure_passed=True,
        )

        self.assertEqual(evidence["coldP95Milliseconds"], 750)
        self.assertEqual(evidence["coldP99Milliseconds"], 750)
        self.assertEqual(evidence["coldMaximumMilliseconds"], 750)
        self.assertEqual(evidence["warmP99Milliseconds"], 150)
        self.assertEqual(evidence["memoryDriftBytes"], 8_000_000)
        self.assertEqual(evidence["memoryDriftFraction"], 0.08)
        self.assertEqual(evidence["coreMLTraceAcceleratorExecutionCount"], 42)

    def test_rejects_any_query_at_or_above_one_second(self) -> None:
        with self.assertRaises(SystemExit):
            MODULE.build_evidence(
                snapshot(at_least_one_second=1),
                9,
                device_model="iPhone11,8",
                os_version="18.6",
                trace_count=1,
                jetsam_count=0,
                contention_fallback_p99=590,
                gpu_contention_passed=True,
                low_power_passed=True,
                memory_pressure_passed=True,
            )

    def test_rejects_missing_stress_signoff(self) -> None:
        with self.assertRaises(SystemExit):
            MODULE.build_evidence(
                snapshot(),
                9,
                device_model="iPhone11,8",
                os_version="18.6",
                trace_count=1,
                jetsam_count=0,
                contention_fallback_p99=590,
                gpu_contention_passed=False,
                low_power_passed=True,
                memory_pressure_passed=True,
            )


if __name__ == "__main__":
    unittest.main()
