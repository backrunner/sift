import unittest

from record_device_metrics import merge_device_metrics


class RecordDeviceMetricsTests(unittest.TestCase):
    def test_requires_full_extension_run_counts(self) -> None:
        benchmark = {
            "computePlan": {"accelerationVerified": True},
            "peakPhysicalFootprintBytes": 100,
            "p95LatencyMilliseconds": 100,
            "p99LatencyMilliseconds": 150,
        }
        extension = {
            "coldP95Milliseconds": 700,
            "coldP99Milliseconds": 850,
            "coldMaximumMilliseconds": 950,
            "warmP95Milliseconds": 120,
            "warmP99Milliseconds": 200,
            "contentionFallbackP99Milliseconds": 550,
            "jetsamCount": 0,
            "memoryDriftBytes": 10,
            "memoryDriftFraction": 0.01,
            "coldRunCount": 29,
            "warmQueryCount": 10_000,
            "coreMLTraceAcceleratorExecutionCount": 1,
            "gpuContentionPassed": True,
            "lowPowerPassed": True,
            "memoryPressurePassed": True,
        }

        with self.assertRaisesRegex(SystemExit, "30 cold runs"):
            merge_device_metrics({}, benchmark, extension, benchmark, extension)

    def test_merges_compute_plan_and_extension_evidence(self) -> None:
        benchmark = {
            "computePlan": {
                "accelerationVerified": True,
                "highestCostOperationDevice": "neuralEngine",
                "neuralEnginePreferredCost": 0.8,
            },
            "peakPhysicalFootprintBytes": 100,
            "p50LatencyMilliseconds": 50,
            "p95LatencyMilliseconds": 100,
            "p99LatencyMilliseconds": 150,
        }
        extension = {
            "coldP95Milliseconds": 700,
            "coldP99Milliseconds": 850,
            "coldMaximumMilliseconds": 950,
            "warmP95Milliseconds": 120,
            "warmP99Milliseconds": 200,
            "contentionFallbackP99Milliseconds": 550,
            "jetsamCount": 0,
            "memoryDriftBytes": 10,
            "memoryDriftFraction": 0.01,
            "coldRunCount": 30,
            "warmQueryCount": 10_000,
            "coreMLTraceAcceleratorExecutionCount": 1,
            "gpuContentionPassed": True,
            "lowPowerPassed": True,
            "memoryPressurePassed": True,
        }

        current_extension = {**extension, "deviceModel": "current-iPhone"}
        result = merge_device_metrics(
            {"profileID": "w8"}, benchmark, extension, benchmark, current_extension
        )

        self.assertTrue(result["deviceMetrics"]["accelerationVerified"])
        self.assertEqual(result["deviceMetrics"]["extensionColdP99Milliseconds"], 850)
        self.assertTrue(result["deviceMetrics"]["stressConditionsPassed"])
        self.assertEqual(result["deviceMetrics"]["currentDevice"]["deviceModel"], "current-iPhone")


if __name__ == "__main__":
    unittest.main()
