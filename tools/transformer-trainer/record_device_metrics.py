#!/usr/bin/env python3
"""Merge signed-off release-device evidence into a candidate report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--runtime-benchmark", type=Path, required=True, help="runtime benchmark JSON from the release device")
    parser.add_argument("--extension-evidence", type=Path, required=True, help="actual IdentityLookup extension timing/jetsam JSON")
    return parser.parse_args()


def validate_extension_evidence(extension: dict, device_name: str) -> None:
    required_extension_fields = [
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
        "computeUnits",
        "coreMLTraceAcceleratorExecutionCount",
    ]
    if extension.get("computeUnits") == "cpuOnly":
        required_extension_fields.append("cpuOnlyReleaseStressPassed")
    else:
        required_extension_fields.extend((
            "gpuContentionPassed",
            "lowPowerPassed",
            "memoryPressurePassed",
        ))
    missing = [field for field in required_extension_fields if field not in extension]
    if missing:
        raise SystemExit(f"error: {device_name} extension evidence missing: {', '.join(missing)}")
    if extension["coldRunCount"] < 30 or extension["warmQueryCount"] < 10_000:
        raise SystemExit(
            f"error: {device_name} extension evidence requires at least 30 cold runs and 10,000 warm queries"
        )
    if extension.get("computeUnits") == "cpuOnly":
        if extension.get("cpuOnlyReleaseStressPassed") is not True:
            raise SystemExit(f"error: {device_name} CPU-only release stress gate failed")
    elif not all((
        extension.get("gpuContentionPassed"),
        extension.get("lowPowerPassed"),
        extension.get("memoryPressurePassed"),
    )):
        raise SystemExit(f"error: {device_name} stress-condition sign-offs are incomplete")


def device_metrics(benchmark: dict, extension: dict) -> dict:
    compute_plan = benchmark.get("computePlan", {})
    trace_count = extension["coreMLTraceAcceleratorExecutionCount"]
    compute_units = benchmark.get("computeUnits")
    if extension.get("computeUnits") != compute_units:
        raise SystemExit("error: runtime benchmark and MessageFilter evidence compute units differ")
    acceleration_verified = bool(compute_plan.get("accelerationVerified")) and trace_count > 0
    cpu_plan_verified = (
        compute_units == "cpuOnly"
        and compute_plan.get("highestCostOperationDevice") == "cpu"
        and compute_plan.get("cpuPreferredCost", 0) > 0
    )
    baseline_footprint = benchmark.get("baselinePhysicalFootprintBytes", 0)
    average_footprint = benchmark.get("averagePhysicalFootprintBytes", 0)
    peak_footprint = benchmark.get("peakPhysicalFootprintBytes", 0)
    return {
        "runtimeExecutionVerified": acceleration_verified or cpu_plan_verified,
        "accelerationVerified": acceleration_verified,
        "computePlanAccelerationVerified": bool(compute_plan.get("accelerationVerified")),
        "coreMLTraceAcceleratorExecutionCount": trace_count,
        "highestCostOperationDevice": compute_plan.get("highestCostOperationDevice"),
        "cpuPreferredCost": compute_plan.get("cpuPreferredCost", 0),
        "gpuPreferredCost": compute_plan.get("gpuPreferredCost", 0),
        "neuralEnginePreferredCost": compute_plan.get("neuralEnginePreferredCost", 0),
        "computeUnits": compute_units,
        "baselinePhysicalFootprintBytes": baseline_footprint,
        "postLoadPhysicalFootprintBytes": benchmark.get("postLoadPhysicalFootprintBytes", 0),
        "postWarmupPhysicalFootprintBytes": benchmark.get("postWarmupPhysicalFootprintBytes", 0),
        "firstExecutionPeakPhysicalFootprintBytes": benchmark.get(
            "firstExecutionPeakPhysicalFootprintBytes", peak_footprint
        ),
        "averagePhysicalFootprintBytes": average_footprint,
        "averagePhysicalFootprintIncreaseBytes": benchmark.get(
            "averagePhysicalFootprintIncreaseBytes", max(0, average_footprint - baseline_footprint)
        ),
        "steadyStatePeakPhysicalFootprintBytes": benchmark.get(
            "steadyStatePeakPhysicalFootprintBytes", peak_footprint
        ),
        "steadyStatePeakPhysicalFootprintIncreaseBytes": benchmark.get(
            "steadyStatePeakPhysicalFootprintIncreaseBytes",
            max(0, peak_footprint - baseline_footprint),
        ),
        "peakPhysicalFootprintBytes": peak_footprint,
        "peakPhysicalFootprintIncreaseBytes": benchmark.get(
            "peakPhysicalFootprintIncreaseBytes", max(0, peak_footprint - baseline_footprint)
        ),
        "finalPhysicalFootprintBytes": benchmark.get("finalPhysicalFootprintBytes", 0),
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
        "stressConditionsPassed": (
            extension.get("cpuOnlyReleaseStressPassed") is True
            if compute_units == "cpuOnly"
            else all((
                extension.get("gpuContentionPassed"),
                extension.get("lowPowerPassed"),
                extension.get("memoryPressurePassed"),
            ))
        ),
        "deviceModel": extension.get("deviceModel"),
        "osVersion": extension.get("osVersion"),
    }


def merge_device_metrics(
    report: dict,
    benchmark: dict,
    extension: dict,
) -> dict:
    validate_extension_evidence(extension, "release-device")
    release_device = device_metrics(benchmark, extension)

    report = dict(report)
    report["deviceMetrics"] = release_device
    return report


def main() -> None:
    arguments = parse_arguments()
    report = json.loads(arguments.report.read_text(encoding="utf-8"))
    benchmark = json.loads(arguments.runtime_benchmark.read_text(encoding="utf-8"))
    extension = json.loads(arguments.extension_evidence.read_text(encoding="utf-8"))
    merged = merge_device_metrics(report, benchmark, extension)
    arguments.report.write_text(json.dumps(merged, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"updated: {arguments.report}")


if __name__ == "__main__":
    main()
