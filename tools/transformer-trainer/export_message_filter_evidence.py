#!/usr/bin/env python3
"""Convert privacy-safe on-device MessageFilter measurements into release evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
from typing import Any


BOUNDED_BUCKETS: tuple[tuple[str, float], ...] = (
    ("under150Milliseconds", 150.0),
    ("under250Milliseconds", 250.0),
    ("under500Milliseconds", 500.0),
    ("under600Milliseconds", 600.0),
    ("under750Milliseconds", 750.0),
    ("under900Milliseconds", 900.0),
    ("under1000Milliseconds", 1000.0),
)
UNBOUNDED_BUCKET = "atLeast1000Milliseconds"


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--release-sequence", type=int)
    parser.add_argument("--device-model", required=True)
    parser.add_argument("--os-version", required=True)
    parser.add_argument("--runtime-benchmark", type=Path, required=True)
    parser.add_argument("--coreml-trace", type=Path)
    parser.add_argument("--coreml-trace-accelerator-execution-count", type=int, default=0)
    parser.add_argument("--jetsam-count", type=int, required=True)
    parser.add_argument("--contention-fallback-p99-ms", type=float)
    parser.add_argument("--gpu-contention-passed", action="store_true")
    parser.add_argument("--low-power-passed", action="store_true")
    parser.add_argument("--memory-pressure-passed", action="store_true")
    return parser.parse_args()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def select_release(snapshot: dict[str, Any], release_sequence: int | None) -> dict[str, Any]:
    releases = list(snapshot.get("releases", {}).values())
    releases = [
        release for release in releases
        if release.get("requestedArtifactIdentity", {}).get("variant") == "transformer"
    ]
    if release_sequence is not None:
        releases = [
            release for release in releases
            if release.get("requestedArtifactIdentity", {}).get("releaseSequence") == release_sequence
        ]
    if len(releases) != 1:
        raise SystemExit("error: snapshot must contain exactly one matching Transformer release")
    return releases[0]


def validate_buckets(buckets: dict[str, Any], name: str) -> dict[str, int]:
    known = {bucket for bucket, _ in BOUNDED_BUCKETS} | {UNBOUNDED_BUCKET}
    unknown = sorted(set(buckets) - known)
    if unknown:
        raise SystemExit(f"error: {name} contains unknown latency buckets: {', '.join(unknown)}")
    normalized = {bucket: int(buckets.get(bucket, 0)) for bucket in known}
    if any(count < 0 for count in normalized.values()):
        raise SystemExit(f"error: {name} contains a negative bucket count")
    if normalized[UNBOUNDED_BUCKET] > 0:
        raise SystemExit(f"error: {name} contains one or more MessageFilter queries at or above 1 second")
    return normalized


def percentile_upper_bound(buckets: dict[str, int], percentile: float) -> float:
    count = sum(buckets.values())
    if count <= 0:
        raise SystemExit("error: cannot calculate a percentile from an empty histogram")
    rank = max(1, math.ceil(count * percentile))
    cumulative = 0
    for bucket, upper_bound in BOUNDED_BUCKETS:
        cumulative += buckets.get(bucket, 0)
        if cumulative >= rank:
            return upper_bound
    raise SystemExit("error: latency histogram does not contain the declared query count")


def maximum_upper_bound(buckets: dict[str, int]) -> float:
    for bucket, upper_bound in reversed(BOUNDED_BUCKETS):
        if buckets.get(bucket, 0) > 0:
            return upper_bound
    raise SystemExit("error: cannot calculate a maximum from an empty histogram")


def build_evidence(
    snapshot: dict[str, Any],
    release_sequence: int | None,
    *,
    device_model: str,
    os_version: str,
    trace_count: int,
    jetsam_count: int,
    contention_fallback_p99: float | None,
    gpu_contention_passed: bool,
    low_power_passed: bool,
    memory_pressure_passed: bool,
    runtime_benchmark: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if snapshot.get("schemaVersion") != 1:
        raise SystemExit("error: unsupported MessageFilter evidence snapshot schema")
    release = select_release(snapshot, release_sequence)
    cold_count = int(release.get("coldRunCount", 0))
    warm_count = int(release.get("warmQueryCount", 0))
    if cold_count < 30 or warm_count < 10_000:
        raise SystemExit("error: MessageFilter evidence requires at least 30 cold runs and 10,000 warm queries")
    cold = validate_buckets(release.get("coldLatencyBuckets", {}), "cold evidence")
    warm = validate_buckets(release.get("warmLatencyBuckets", {}), "warm evidence")
    if sum(cold.values()) != cold_count or sum(warm.values()) != warm_count:
        raise SystemExit("error: MessageFilter histogram counts do not match the declared query counts")
    if jetsam_count != 0:
        raise SystemExit("error: MessageFilter evidence contains a jetsam event")

    first_footprint = int(release.get("firstPhysicalFootprintBytes", 0))
    latest_footprint = int(release.get("latestPhysicalFootprintBytes", 0))
    if first_footprint <= 0 or latest_footprint <= 0:
        raise SystemExit("error: MessageFilter footprint evidence is missing")
    signed_memory_change_bytes = latest_footprint - first_footprint
    drift_bytes = max(0, signed_memory_change_bytes)
    drift_fraction = drift_bytes / first_footprint
    if int(release.get("watchdogCount", 0)) != 0:
        raise SystemExit("error: MessageFilter evidence contains a watchdog timeout")
    if release.get("errorCounts", {}):
        raise SystemExit("error: MessageFilter evidence contains classification errors")
    fallback_counts = release.get("fallbackCounts", {})
    unexpected_fallbacks = sum(
        int(count) for reason, count in fallback_counts.items() if reason != "none"
    )
    if unexpected_fallbacks != 0:
        raise SystemExit("error: MessageFilter evidence contains a model fallback")

    runtime_benchmark = runtime_benchmark or {}
    compute_units = runtime_benchmark.get("computeUnits")
    cpu_only = compute_units == "cpuOnly"
    if cpu_only:
        compute_plan = runtime_benchmark.get("computePlan", {})
        if (
            compute_plan.get("highestCostOperationDevice") != "cpu"
            or compute_plan.get("cpuPreferredCost", 0) <= 0
        ):
            raise SystemExit("error: CPU-only benchmark lacks a matching Core ML compute plan")
        if (
            runtime_benchmark.get("p99LatencyMilliseconds", float("inf")) > 250
            or runtime_benchmark.get("peakPhysicalFootprintIncreaseBytes", float("inf"))
            > 256 * 1024 * 1024
        ):
            raise SystemExit("error: CPU-only runtime headroom gate failed")
        if drift_bytes > 16 * 1024 * 1024 or drift_fraction > 0.10:
            raise SystemExit("error: CPU-only MessageFilter memory drift gate failed")
        contention_fallback_p99 = contention_fallback_p99 or percentile_upper_bound(warm, 0.99)
    else:
        if trace_count <= 0:
            raise SystemExit("error: Core ML trace must contain non-zero accelerator execution")
        if contention_fallback_p99 is None or contention_fallback_p99 > 600:
            raise SystemExit("error: contention fallback P99 exceeds 600 ms")
        if not all((gpu_contention_passed, low_power_passed, memory_pressure_passed)):
            raise SystemExit("error: all stress-condition sign-offs are required")

    return {
        "coldP95Milliseconds": percentile_upper_bound(cold, 0.95),
        "coldP99Milliseconds": percentile_upper_bound(cold, 0.99),
        "coldMaximumMilliseconds": maximum_upper_bound(cold),
        "warmP95Milliseconds": percentile_upper_bound(warm, 0.95),
        "warmP99Milliseconds": percentile_upper_bound(warm, 0.99),
        "contentionFallbackP99Milliseconds": contention_fallback_p99,
        "jetsamCount": jetsam_count,
        "memoryDriftBytes": drift_bytes,
        "memoryDriftFraction": drift_fraction,
        "signedMemoryChangeBytes": signed_memory_change_bytes,
        "coldRunCount": cold_count,
        "warmQueryCount": warm_count,
        "computeUnits": compute_units,
        "coreMLTraceAcceleratorExecutionCount": trace_count,
        "cpuOnlyReleaseStressPassed": cpu_only,
        "gpuContentionPassed": gpu_contention_passed,
        "lowPowerPassed": low_power_passed,
        "memoryPressurePassed": memory_pressure_passed,
        "deviceModel": device_model,
        "osVersion": os_version,
        "requestedArtifactIdentity": release.get("requestedArtifactIdentity"),
        "peakPhysicalFootprintBytes": int(release.get("peakPhysicalFootprintBytes", 0)),
        "watchdogCount": int(release.get("watchdogCount", 0)),
        "fallbackCounts": release.get("fallbackCounts", {}),
        "errorCounts": release.get("errorCounts", {}),
        "coldLatencyBuckets": release.get("coldLatencyBuckets", {}),
        "warmLatencyBuckets": release.get("warmLatencyBuckets", {}),
    }


def main() -> None:
    arguments = parse_arguments()
    if not arguments.snapshot.is_file():
        raise SystemExit(f"error: snapshot not found: {arguments.snapshot}")
    if not arguments.runtime_benchmark.is_file():
        raise SystemExit(f"error: runtime benchmark not found: {arguments.runtime_benchmark}")
    if arguments.coreml_trace is not None and not arguments.coreml_trace.is_file():
        raise SystemExit(f"error: Core ML trace not found: {arguments.coreml_trace}")
    snapshot = json.loads(arguments.snapshot.read_text(encoding="utf-8"))
    runtime_benchmark = json.loads(arguments.runtime_benchmark.read_text(encoding="utf-8"))
    evidence = build_evidence(
        snapshot,
        arguments.release_sequence,
        device_model=arguments.device_model,
        os_version=arguments.os_version,
        trace_count=arguments.coreml_trace_accelerator_execution_count,
        jetsam_count=arguments.jetsam_count,
        contention_fallback_p99=arguments.contention_fallback_p99_ms,
        gpu_contention_passed=arguments.gpu_contention_passed,
        low_power_passed=arguments.low_power_passed,
        memory_pressure_passed=arguments.memory_pressure_passed,
        runtime_benchmark=runtime_benchmark,
    )
    evidence["sourceSnapshotSHA256"] = file_sha256(arguments.snapshot)
    evidence["runtimeBenchmarkSHA256"] = file_sha256(arguments.runtime_benchmark)
    if arguments.coreml_trace is not None:
        evidence["coreMLTraceSHA256"] = file_sha256(arguments.coreml_trace)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote: {arguments.output}")


if __name__ == "__main__":
    main()
