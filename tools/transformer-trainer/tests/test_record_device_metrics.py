import unittest

from record_device_metrics import merge_device_metrics


class RecordDeviceMetricsTests(unittest.TestCase):
    def test_requires_full_extension_run_counts(self) -> None:
        benchmark = {
            "computeUnits": "all",
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
            "computeUnits": "all",
            "coreMLTraceAcceleratorExecutionCount": 1,
            "gpuContentionPassed": True,
            "lowPowerPassed": True,
            "memoryPressurePassed": True,
        }

        with self.assertRaisesRegex(SystemExit, "30 cold runs"):
            merge_device_metrics({}, benchmark, extension)

    def test_merges_compute_plan_and_extension_evidence(self) -> None:
        benchmark = {
            "computeUnits": "all",
            "computePlan": {
                "accelerationVerified": True,
                "highestCostOperationDevice": "neuralEngine",
                "neuralEnginePreferredCost": 0.8,
            },
            "peakPhysicalFootprintBytes": 100,
            "averagePhysicalFootprintBytes": 90,
            "baselinePhysicalFootprintBytes": 40,
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
            "computeUnits": "all",
            "coreMLTraceAcceleratorExecutionCount": 1,
            "gpuContentionPassed": True,
            "lowPowerPassed": True,
            "memoryPressurePassed": True,
        }

        extension["deviceModel"] = "release-iPhone"
        result = merge_device_metrics({"profileID": "w8"}, benchmark, extension)

        self.assertTrue(result["deviceMetrics"]["accelerationVerified"])
        self.assertTrue(result["deviceMetrics"]["runtimeExecutionVerified"])
        self.assertEqual(result["deviceMetrics"]["extensionColdP99Milliseconds"], 850)
        self.assertTrue(result["deviceMetrics"]["stressConditionsPassed"])
        self.assertEqual(result["deviceMetrics"]["deviceModel"], "release-iPhone")
        self.assertEqual(result["deviceMetrics"]["averagePhysicalFootprintIncreaseBytes"], 50)
        self.assertEqual(result["deviceMetrics"]["peakPhysicalFootprintIncreaseBytes"], 60)

    def test_cpu_only_plan_is_valid_runtime_evidence_without_accelerator_trace(self) -> None:
        benchmark = {
            "computeUnits": "cpuOnly",
            "computePlan": {
                "accelerationVerified": False,
                "highestCostOperationDevice": "cpu",
                "cpuPreferredCost": 0.8,
            },
            "peakPhysicalFootprintBytes": 100,
            "averagePhysicalFootprintBytes": 90,
            "baselinePhysicalFootprintBytes": 40,
            "p95LatencyMilliseconds": 2,
            "p99LatencyMilliseconds": 3,
        }
        extension = {
            "coldP95Milliseconds": 10,
            "coldP99Milliseconds": 12,
            "coldMaximumMilliseconds": 15,
            "warmP95Milliseconds": 2,
            "warmP99Milliseconds": 3,
            "contentionFallbackP99Milliseconds": 4,
            "jetsamCount": 0,
            "memoryDriftBytes": 0,
            "memoryDriftFraction": 0,
            "coldRunCount": 30,
            "warmQueryCount": 10_000,
            "computeUnits": "cpuOnly",
            "coreMLTraceAcceleratorExecutionCount": 0,
            "cpuOnlyReleaseStressPassed": True,
            "gpuContentionPassed": True,
            "lowPowerPassed": True,
            "memoryPressurePassed": True,
        }

        result = merge_device_metrics({"profileID": "w8"}, benchmark, extension)

        self.assertTrue(result["deviceMetrics"]["runtimeExecutionVerified"])
        self.assertFalse(result["deviceMetrics"]["accelerationVerified"])


if __name__ == "__main__":
    unittest.main()
