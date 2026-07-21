#!/usr/bin/env python3
"""Select the smallest Transformer candidate that passes every release gate."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


QUALITY_FAILURES = frozenset({
    "fixedAccuracy",
    "promotionAccuracy",
    "conversationAccuracy",
    "conversationActionAccuracy",
    "fixedDrop",
    "promotionDrop",
    "fp16Top1Agreement",
    "probabilitiesFinite",
    "probabilitySumsValid",
    "zhDrop",
    "enDrop",
    "jaDrop",
    "messageFilterFixedAccuracy",
    "messageFilterPromotionAccuracy",
    "messageFilterConversationAccuracy",
    "benignOrTransactionToJunk",
    "promotionFalsePositiveRate",
    "scamJunkRecall",
    "rulesOverrideRate",
    "readableCaseSuite",
    "readableCases",
})


def has_quality_failure(failures: list[str]) -> bool:
    return any(failure in QUALITY_FAILURES for failure in failures)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profiles", type=Path, default=Path(__file__).with_name("quantization-profiles.json"))
    parser.add_argument("--reports", type=Path, required=True, help="directory containing <profile-id>.report.json")
    parser.add_argument("--out", type=Path, required=True, help="selected-candidate.json output")
    return parser.parse_args()


def load_profiles(path: Path) -> dict[str, dict[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schemaVersion") != 1 or not isinstance(payload.get("profiles"), list):
        raise SystemExit("error: unsupported quantization profile schema")
    profiles = {item["id"]: item for item in payload["profiles"]}
    if len(profiles) != len(payload["profiles"]):
        raise SystemExit("error: duplicate quantization profile id")
    return profiles


def load_reports(directory: Path) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for path in sorted(directory.glob("*.report.json")):
        report = json.loads(path.read_text(encoding="utf-8"))
        report["_reportPath"] = str(path.resolve())
        reports.append(report)
    if not reports:
        raise SystemExit(f"error: no candidate reports found in {directory}")
    return reports


def candidate_failures(report: dict[str, Any], fp16: dict[str, Any]) -> list[str]:
    metrics = report.get("metrics", {})
    actions = report.get("messageFilterActions", {})
    device = report.get("deviceMetrics", {})
    fp16_metrics = fp16.get("metrics", {})
    failures: list[str] = []

    def require(condition: bool, name: str) -> None:
        if not condition:
            failures.append(name)

    require(metrics.get("fixedAccuracy", 0) >= 0.99, "fixedAccuracy")
    require(metrics.get("promotionAccuracy", 0) >= 0.97, "promotionAccuracy")
    require(metrics.get("conversationAccuracy", 0) >= 1.0, "conversationAccuracy")
    require(metrics.get("conversationActionAccuracy", 0) >= 1.0, "conversationActionAccuracy")
    require(fp16_metrics.get("fixedAccuracy", 0) - metrics.get("fixedAccuracy", 0) <= 0.01, "fixedDrop")
    require(fp16_metrics.get("promotionAccuracy", 0) - metrics.get("promotionAccuracy", 0) <= 0.01, "promotionDrop")
    require(metrics.get("fp16Top1Agreement", 0) >= 0.985, "fp16Top1Agreement")
    require(bool(metrics.get("probabilitiesFinite")), "probabilitiesFinite")
    require(bool(metrics.get("probabilitySumsValid")), "probabilitySumsValid")
    for language in ("zh", "en", "ja"):
        candidate_score = metrics.get("languageAccuracy", {}).get(language, 0)
        baseline_score = fp16_metrics.get("languageAccuracy", {}).get(language, 0)
        require(baseline_score - candidate_score <= 0.015, f"{language}Drop")

    require(actions.get("fixedAccuracy", 0) >= 0.99, "messageFilterFixedAccuracy")
    require(actions.get("promotionAccuracy", 0) >= 0.97, "messageFilterPromotionAccuracy")
    require(actions.get("conversationAccuracy", 0) >= 1.0, "messageFilterConversationAccuracy")
    require(actions.get("benignOrTransactionToJunk", 1) == 0, "benignOrTransactionToJunk")
    require(actions.get("promotionFalsePositiveRate", 1) <= 0.01, "promotionFalsePositiveRate")
    require(actions.get("scamJunkRecall", 0) >= 1.0, "scamJunkRecall")
    require(actions.get("rulesOverrideRate", 0) >= 1.0, "rulesOverrideRate")
    readable_cases = actions.get("readableCases", [])
    require(actions.get("readableCaseSuiteVersion", 0) >= 2, "readableCaseSuite")
    require(
        isinstance(readable_cases, list)
        and actions.get("readableCaseCount", 0) == len(readable_cases)
        and len(readable_cases) >= 17
        and all(item.get("passed") is True for item in readable_cases),
        "readableCases",
    )

    require(bool(device.get("runtimeExecutionVerified")), "runtimeExecutionVerified")
    require(device.get("peakPhysicalFootprintBytes", 0) > 0, "peakPhysicalFootprintBytes")
    require(device.get("peakPhysicalFootprintIncreaseBytes", float("inf")) <= 256 * 1024 * 1024, "peakPhysicalFootprintIncreaseBytes")
    require(
        device.get("averagePhysicalFootprintIncreaseBytes", float("inf")) <= 256 * 1024 * 1024,
        "averagePhysicalFootprintIncreaseBytes",
    )
    require(device.get("p95LatencyMilliseconds", 0) > 0, "p95LatencyMilliseconds")
    require(device.get("p95LatencyMilliseconds", float("inf")) <= 150, "p95Latency")
    require(device.get("p99LatencyMilliseconds", float("inf")) <= 250, "p99Latency")
    require(device.get("extensionColdP95Milliseconds", float("inf")) <= 750, "extensionColdP95")
    require(device.get("extensionColdP99Milliseconds", float("inf")) <= 900, "extensionColdP99")
    require(device.get("extensionColdMaximumMilliseconds", float("inf")) < 1000, "extensionColdMaximum")
    require(device.get("extensionWarmP95Milliseconds", float("inf")) <= 150, "extensionWarmP95")
    require(device.get("extensionWarmP99Milliseconds", float("inf")) <= 250, "extensionWarmP99")
    if device.get("computeUnits") != "cpuOnly":
        require(device.get("contentionFallbackP99Milliseconds", float("inf")) <= 600, "contentionFallbackP99")
    require(device.get("jetsamCount", 1) == 0, "jetsamCount")
    require(device.get("memoryDriftBytes", float("inf")) <= 16 * 1024 * 1024, "memoryDriftBytes")
    require(device.get("memoryDriftFraction", float("inf")) <= 0.10, "memoryDriftFraction")
    require(bool(device.get("stressConditionsPassed")), "stressConditionsPassed")
    if device.get("computeUnits") == "cpuOnly":
        require(report.get("downloadBytes", float("inf")) <= 0.75 * fp16.get("downloadBytes", 0), "fp16ResourceReduction")
    else:
        require(
            device.get("peakPhysicalFootprintIncreaseBytes", float("inf"))
            <= 0.75 * fp16.get("deviceMetrics", {}).get("peakPhysicalFootprintIncreaseBytes", 0),
            "fp16ResourceReduction",
        )
    require(report.get("artifactSHA256") not in (None, ""), "artifactSHA256")
    require(report.get("downloadBytes", 0) > 0, "downloadBytes")
    return failures


def within_five_percent(candidates: list[dict[str, Any]], value) -> list[dict[str, Any]]:
    minimum = min(value(item) for item in candidates)
    return [item for item in candidates if value(item) <= minimum * 1.05]


def select_candidate(profiles: dict[str, dict[str, Any]], reports: list[dict[str, Any]]) -> dict[str, Any]:
    by_id = {report.get("profileID"): report for report in reports}
    fp16 = by_id.get("fp16-baseline")
    if fp16 is None:
        raise SystemExit("error: fp16-baseline report is required")

    eligible: list[dict[str, Any]] = []
    rejected: dict[str, list[str]] = {}
    qat_required: set[str] = set()
    for profile_id, profile in profiles.items():
        if not profile.get("eligibleForRelease") or profile.get("enabledWhenPTQQualityFails"):
            continue
        report = by_id.get(profile_id)
        if report is None:
            rejected[profile_id] = ["missingReport"]
            continue
        failures = candidate_failures(report, fp16)
        if failures:
            rejected[profile_id] = failures
            if (
                profile.get("weightBits") == 4
                and profile.get("qatFallback")
                and has_quality_failure(failures)
            ):
                qat_required.add(profile["qatFallback"])
        else:
            eligible.append(report)

    for profile_id in sorted(qat_required):
        report = by_id.get(profile_id)
        if report is None:
            rejected[profile_id] = ["qatRequired", "missingReport"]
            continue
        failures = candidate_failures(report, fp16)
        if failures:
            rejected[profile_id] = failures
        else:
            eligible.append(report)

    if not eligible:
        detail = ", ".join(f"{key}: {'/'.join(value)}" for key, value in sorted(rejected.items()))
        raise SystemExit(f"error: no int8/int4 candidate passed all release gates ({detail})")

    eligible = within_five_percent(eligible, lambda item: item["deviceMetrics"]["peakPhysicalFootprintIncreaseBytes"])
    eligible = within_five_percent(eligible, lambda item: item["downloadBytes"])
    eligible = within_five_percent(eligible, lambda item: item["deviceMetrics"]["p95LatencyMilliseconds"])
    eligible.sort(key=lambda item: (-item["metrics"]["promotionAccuracy"], item["profileID"]))
    winner = eligible[0]
    return {
        "schemaVersion": 1,
        "profileID": winner["profileID"],
        "artifactSHA256": winner["artifactSHA256"],
        "reportSHA256": hashlib.sha256(Path(winner["_reportPath"]).read_bytes()).hexdigest(),
        "reportPath": winner["_reportPath"],
        "rejectedCandidates": rejected,
    }


def main() -> None:
    arguments = parse_arguments()
    selection = select_candidate(load_profiles(arguments.profiles), load_reports(arguments.reports))
    arguments.out.parent.mkdir(parents=True, exist_ok=True)
    arguments.out.write_text(json.dumps(selection, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"selected: {selection['profileID']} ({selection['artifactSHA256']})")
    print(f"report: {arguments.out}")


if __name__ == "__main__":
    main()
