#!/usr/bin/env python3
"""Select the smallest Transformer candidate that passes every release gate."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from check_distillation_gate import gate_matches_student, is_distilled, read_report


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
    parser.add_argument(
        "--distillation-gate",
        type=Path,
        action="append",
        default=[],
        help=(
            "gate JSON produced by check_distillation_gate.py; repeat for multiple candidates. "
            "When omitted, distillation-gate*.json is discovered beside --reports."
        ),
    )
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


def discover_distillation_gates(reports_directory: Path) -> list[Path]:
    """Find gate artifacts emitted next to a quantization tournament."""
    candidates = set(reports_directory.glob("distillation-gate*.json"))
    candidates.update(reports_directory.parent.glob("distillation-gate*.json"))
    return sorted(path.resolve() for path in candidates if path.is_file())


def load_distillation_gates(paths: list[Path]) -> list[dict[str, Any]]:
    gates: list[dict[str, Any]] = []
    for raw_path in paths:
        path = raw_path.expanduser().resolve()
        if not path.is_file():
            raise SystemExit(f"error: distillation gate not found: {path}")
        gate = read_report(path)
        gate["_gatePath"] = str(path)
        gate["_gateSHA256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        gates.append(gate)
    return gates


def gate_for_report(
    report: dict[str, Any],
    gates: list[dict[str, Any]],
    *,
    expected_teacher: dict[str, Any] | None = None,
    expected_teacher_report_sha256: str | None = None,
) -> tuple[dict[str, Any] | None, str | None]:
    """Return the one passing gate bound to a distilled report."""
    if not is_distilled(report):
        return None, None
    report_path = Path(str(report.get("_reportPath", "")))
    report_sha = hashlib.sha256(report_path.read_bytes()).hexdigest() if report_path.is_file() else None
    matching: list[dict[str, Any]] = []
    failures: list[str] = []
    for gate in gates:
        valid, reason = gate_matches_student(
            gate,
            report,
            student_report_sha256=report_sha,
            expected_teacher=expected_teacher,
            expected_teacher_report_sha256=expected_teacher_report_sha256,
        )
        if valid:
            matching.append(gate)
        else:
            # Keep a useful error for a gate that is clearly intended for this
            # candidate; unrelated candidate gates are simply skipped.
            student = gate.get("student") if isinstance(gate.get("student"), dict) else {}
            profile = student.get("profileID") or gate.get("studentProfileID")
            artifact = student.get("artifactSHA256") or gate.get("studentArtifactSHA256")
            if profile == report.get("profileID") or artifact == report.get("artifactSHA256"):
                failures.append(reason)
    if len(matching) > 1:
        return None, "multiple gates match candidate"
    if matching:
        return matching[0], None
    return None, failures[0] if failures else "no matching gate"


def candidate_failures(report: dict[str, Any], fp16: dict[str, Any]) -> list[str]:
    metrics = report.get("metrics", {})
    actions = report.get("messageFilterActions", {})
    device = report.get("deviceMetrics", {})
    fp16_metrics = fp16.get("metrics", {})
    failures: list[str] = []

    def require(condition: bool, name: str) -> None:
        if not condition:
            failures.append(name)

    require(report.get("releaseEligible", True) is True, "releaseEligible")
    require(metrics.get("fixedAccuracy", 0) >= 0.99, "fixedAccuracy")
    require(metrics.get("promotionAccuracy", 0) >= 0.98, "promotionAccuracy")
    require(metrics.get("billingAccuracy", 0) >= 0.90, "billingAccuracy")
    require(metrics.get("billingActionAccuracy", 0) >= 0.95, "billingActionAccuracy")
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
    require(actions.get("promotionAccuracy", 0) >= 0.98, "messageFilterPromotionAccuracy")
    require(actions.get("billingAccuracy", 0) >= 0.95, "messageFilterBillingAccuracy")
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


def select_candidate(
    profiles: dict[str, dict[str, Any]],
    reports: list[dict[str, Any]],
    distillation_gate: Path | str | dict[str, Any] | list[Path] | list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Select a release candidate, requiring a bound gate for distilled reports."""
    by_id = {report.get("profileID"): report for report in reports}
    fp16 = by_id.get("fp32-baseline")
    if fp16 is None:
        raise SystemExit("error: fp32-baseline report is required")
    teacher_report_path = Path(str(fp16.get("_reportPath", "")))
    teacher_report_sha256 = (
        hashlib.sha256(teacher_report_path.read_bytes()).hexdigest()
        if teacher_report_path.is_file()
        else None
    )

    if distillation_gate is None:
        gates: list[dict[str, Any]] = []
    elif isinstance(distillation_gate, (Path, str)):
        gates = load_distillation_gates([Path(distillation_gate)])
    elif isinstance(distillation_gate, dict):
        gates = [distillation_gate]
    elif isinstance(distillation_gate, (list, tuple)) and all(isinstance(item, (Path, str)) for item in distillation_gate):
        gates = load_distillation_gates([Path(item) for item in distillation_gate])
    else:
        gates = list(distillation_gate or [])

    eligible: list[dict[str, Any]] = []
    rejected: dict[str, list[str]] = {}
    qat_required: set[str] = set()

    def evaluate_report(profile_id: str, report: dict[str, Any], *, qat: bool = False) -> None:
        failures = candidate_failures(report, fp16)
        gate, gate_failure = gate_for_report(
            report,
            gates,
            expected_teacher=fp16,
            expected_teacher_report_sha256=teacher_report_sha256,
        )
        if gate_failure is not None:
            failures.append("distillationGate")
        if failures:
            rejected[profile_id] = (["qatRequired"] if qat else []) + failures
            if (
                not qat
                and profile_id in profiles
                and profiles[profile_id].get("weightBits") == 4
                and profiles[profile_id].get("qatFallback")
                and has_quality_failure(failures)
            ):
                qat_required.add(profiles[profile_id]["qatFallback"])
            return
        candidate = dict(report)
        if gate is not None:
            candidate["_distillationGate"] = gate
        eligible.append(candidate)

    for profile_id, profile in profiles.items():
        if not profile.get("eligibleForRelease") or profile.get("enabledWhenPTQQualityFails"):
            continue
        report = by_id.get(profile_id)
        if report is None:
            rejected[profile_id] = ["missingReport"]
            continue
        evaluate_report(profile_id, report)

    for profile_id in sorted(qat_required):
        report = by_id.get(profile_id)
        if report is None:
            rejected[profile_id] = ["qatRequired", "missingReport"]
            continue
        evaluate_report(profile_id, report, qat=True)

    if not eligible:
        detail = ", ".join(f"{key}: {'/'.join(value)}" for key, value in sorted(rejected.items()))
        raise SystemExit(f"error: no int8/int4 candidate passed all release gates ({detail})")

    eligible = within_five_percent(eligible, lambda item: item["deviceMetrics"]["peakPhysicalFootprintIncreaseBytes"])
    eligible = within_five_percent(eligible, lambda item: item["downloadBytes"])
    eligible = within_five_percent(eligible, lambda item: item["deviceMetrics"]["extensionColdP95Milliseconds"])
    eligible = within_five_percent(eligible, lambda item: item["deviceMetrics"]["p95LatencyMilliseconds"])
    eligible.sort(key=lambda item: (-item["metrics"]["promotionAccuracy"], item["profileID"]))
    winner = eligible[0]
    selection = {
        "schemaVersion": 1,
        "profileID": winner["profileID"],
        "artifactSHA256": winner["artifactSHA256"],
        "reportSHA256": hashlib.sha256(Path(winner["_reportPath"]).read_bytes()).hexdigest(),
        "reportPath": winner["_reportPath"],
        "rejectedCandidates": rejected,
    }
    gate = winner.get("_distillationGate")
    if gate is not None:
        gate_sha = gate.get("_gateSHA256")
        gate_path = gate.get("_gatePath")
        if not isinstance(gate_sha, str) or not isinstance(gate_path, str):
            raise SystemExit("error: selected distilled candidate gate lacks file provenance")
        selection["distillationGateSHA256"] = gate_sha
        selection["distillationGatePath"] = gate_path
        if teacher_report_sha256 is None:
            raise SystemExit("error: selected distilled candidate has no current teacher report hash")
        selection["teacherProfileID"] = fp16.get("profileID")
        selection["teacherArtifactSHA256"] = fp16.get("artifactSHA256")
        selection["teacherReportSHA256"] = teacher_report_sha256
    return selection


def main() -> None:
    arguments = parse_arguments()
    reports = load_reports(arguments.reports)
    gate_paths = arguments.distillation_gate or discover_distillation_gates(arguments.reports)
    selection = select_candidate(
        load_profiles(arguments.profiles),
        reports,
        load_distillation_gates(gate_paths),
    )
    arguments.out.parent.mkdir(parents=True, exist_ok=True)
    arguments.out.write_text(json.dumps(selection, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"selected: {selection['profileID']} ({selection['artifactSHA256']})")
    print(f"report: {arguments.out}")


if __name__ == "__main__":
    main()
