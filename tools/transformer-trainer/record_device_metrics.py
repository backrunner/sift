#!/usr/bin/env python3
"""Merge signed-off A12 extension and Core ML benchmark evidence into a candidate report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--runtime-benchmark", type=Path, required=True, help="TransformerRuntimeBenchmarkReport JSON from A12")
    parser.add_argument("--extension-evidence", type=Path, required=True, help="actual IdentityLookup extension timing/jetsam JSON")
    parser.add_argument("--current-runtime-benchmark", type=Path, required=True, help="benchmark JSON from a current-generation iPhone")
    parser.add_argument("--current-extension-evidence", type=Path, required=True, help="IdentityLookup evidence from a current-generation iPhone")
    return parser.parse_args()


def validate_extension_evidence(extension: dict, device_name: str) -> None:
    required_extension_fields = (
        "coldP95Milliseconds",
        "coldP99Milliseconds",
        "coldMaximumMilliseconds",
        "warmP95Milliseconds",
        "warmP99Milliseconds",
        "contentionFallbackP99Milliseconds",
        "jetsamCount",
        "memoryDriftBytes",
        "memoryDriftFraction",
        "coldRunCount",
        "warmQueryCount",
        "coreMLTraceAcceleratorExecutionCount",
        "gpuContentionPassed",
        "lowPowerPassed",
        "memoryPressurePassed",
    )
    missing = [field for field in required_extension_fields if field not in extension]
    if missing:
        raise SystemExit(f"error: {device_name} extension evidence missing: {', '.join(missing)}")
    if extension["coldRunCount"] < 30 or extension["warmQueryCount"] < 10_000:
        raise SystemExit(
            f"error: {device_name} extension evidence requires at least 30 cold runs and 10,000 warm queries"
        )


def device_metrics(benchmark: dict, extension: dict) -> dict:
    compute_plan = benchmark.get("computePlan", {})
    trace_count = extension["coreMLTraceAcceleratorExecutionCount"]
    return {
        "accelerationVerified": bool(compute_plan.get("accelerationVerified")) and trace_count > 0,
        "computePlanAccelerationVerified": bool(compute_plan.get("accelerationVerified")),
        "coreMLTraceAcceleratorExecutionCount": trace_count,
        "highestCostOperationDevice": compute_plan.get("highestCostOperationDevice"),
        "cpuPreferredCost": compute_plan.get("cpuPreferredCost", 0),
        "gpuPreferredCost": compute_plan.get("gpuPreferredCost", 0),
        "neuralEnginePreferredCost": compute_plan.get("neuralEnginePreferredCost", 0),
        "peakPhysicalFootprintBytes": benchmark.get("peakPhysicalFootprintBytes", 0),
        "coldModelLoadMilliseconds": benchmark.get("coldLoadMilliseconds", 0),
        "p50LatencyMilliseconds": benchmark.get("p50LatencyMilliseconds", 0),
        "p95LatencyMilliseconds": benchmark.get("p95LatencyMilliseconds", 0),
        "p99LatencyMilliseconds": benchmark.get("p99LatencyMilliseconds", 0),
        "extensionColdP95Milliseconds": extension["coldP95Milliseconds"],
        "extensionColdP99Milliseconds": extension["coldP99Milliseconds"],
        "extensionColdMaximumMilliseconds": extension["coldMaximumMilliseconds"],
        "extensionWarmP95Milliseconds": extension["warmP95Milliseconds"],
        "extensionWarmP99Milliseconds": extension["warmP99Milliseconds"],
        "contentionFallbackP99Milliseconds": extension["contentionFallbackP99Milliseconds"],
        "jetsamCount": extension["jetsamCount"],
        "memoryDriftBytes": extension["memoryDriftBytes"],
        "memoryDriftFraction": extension["memoryDriftFraction"],
        "coldRunCount": extension["coldRunCount"],
        "warmQueryCount": extension["warmQueryCount"],
        "stressConditionsPassed": all((
            extension["gpuContentionPassed"],
            extension["lowPowerPassed"],
            extension["memoryPressurePassed"],
        )),
        "deviceModel": extension.get("deviceModel"),
        "osVersion": extension.get("osVersion"),
    }


def merge_device_metrics(
    report: dict,
    benchmark: dict,
    extension: dict,
    current_benchmark: dict,
    current_extension: dict,
) -> dict:
    validate_extension_evidence(extension, "A12")
    validate_extension_evidence(current_extension, "current-generation")
    a12 = device_metrics(benchmark, extension)
    current = device_metrics(current_benchmark, current_extension)

    report = dict(report)
    report["deviceMetrics"] = {
        **a12,
        "a12P50LatencyMilliseconds": a12["p50LatencyMilliseconds"],
        "a12P95LatencyMilliseconds": a12["p95LatencyMilliseconds"],
        "a12P99LatencyMilliseconds": a12["p99LatencyMilliseconds"],
        "currentDevice": current,
    }
    return report


def main() -> None:
    arguments = parse_arguments()
    report = json.loads(arguments.report.read_text(encoding="utf-8"))
    benchmark = json.loads(arguments.runtime_benchmark.read_text(encoding="utf-8"))
    extension = json.loads(arguments.extension_evidence.read_text(encoding="utf-8"))
    current_benchmark = json.loads(arguments.current_runtime_benchmark.read_text(encoding="utf-8"))
    current_extension = json.loads(arguments.current_extension_evidence.read_text(encoding="utf-8"))
    merged = merge_device_metrics(report, benchmark, extension, current_benchmark, current_extension)
    arguments.report.write_text(json.dumps(merged, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"updated: {arguments.report}")


if __name__ == "__main__":
    main()
