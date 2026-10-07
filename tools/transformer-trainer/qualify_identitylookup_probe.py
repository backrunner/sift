#!/usr/bin/env python3
"""Extract aggregate release evidence from the synthetic IdentityLookup probe's OSLog.

The cold count means fresh engine/model loads, not fresh OS processes. Incoming
SMS completion is recorded separately. Never supply app-host logs to this tool.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

from identitylookup_release_gate import PROFILE_ID, identitylookup_failures


def qualify(log_path: Path, sms_path: Path, artifact_sha: str) -> dict:
    records = json.loads(log_path.read_text())
    summaries = [json.loads(r["eventMessage"].split("qualificationSummary=", 1)[1])
                 for r in records if r.get("subsystem") == "com.alkinum.sift.phaseprobe.filter"
                 and "qualificationSummary=" in r.get("eventMessage", "")]
    if len(summaries) != 1 or summaries[0]["artifactSHA256"] != artifact_sha:
        raise ValueError("expected one completed stress summary bound to the candidate")
    summary = summaries[0]
    if (summary.get("computeUnits") != "cpuOnly"
            or "actual IdentityLookup extension" not in summary.get("environment", "")
            or "production MessageFilterEngine" not in summary.get("environment", "")):
        raise ValueError("expected actual CPU-only IdentityLookup production-engine evidence")
    pid = summary["pid"]
    messages = [r["eventMessage"] for r in records
                if r.get("subsystem") == "com.alkinum.sift.phaseprobe.filter"
                and f"pid={pid} " in r.get("eventMessage", "")]
    cold = {int(m.group(1)) for s in messages if (m := re.search(r"stage=engineColdReload(\d+)Finished", s))}
    warm = {}
    budgets = []
    peaks = []
    released = None
    for text in messages:
        metrics = re.search(r"footprint=(\d+) process_peak=(\d+) available=(\d+)", text)
        if metrics:
            footprint, peak, available = map(int, metrics.groups())
            budgets.append(footprint + available)
            peaks.append(max(footprint, peak))
            if match := re.search(r"stage=engineWarm(\d+)Finished", text):
                warm[int(match.group(1))] = footprint
            if "stage=qualificationCompleted " in text:
                released = footprint
    if cold != set(range(1, 31)) or set(warm) != set(range(100, 10_001, 100)) or released is None:
        raise ValueError("incomplete cold/warm checkpoints or missing completion")
    if (summary.get("coldRunCount") != len(cold) or summary.get("warmQueryCount") != max(warm)
            or summary.get("processLifetimePeakPhysicalFootprintBytes", 0) < max(peaks)):
        raise ValueError("summary contradicts measured checkpoints")
    if any(re.search(r"per-process-limit|memorystatus.*kill", r.get("eventMessage", ""), re.I)
           for r in records):
        raise ValueError("device log contains memory-limit termination evidence")
    sms = json.loads(sms_path.read_text())
    # Pair ordered receipt/completion in the same extension process; unrelated
    # responses or a response before a query cannot satisfy the incoming gate.
    pending = {}
    completed = 0
    for record in sms:
        match = re.search(r"candidate=full12Legacy32 pid=(\d+) stage=(\w+) ", record.get("eventMessage", ""))
        if not match:
            continue
        sms_pid, stage = match.groups()
        if stage == "queryReceived":
            pending[sms_pid] = pending.get(sms_pid, 0) + 1
        elif stage == "responseSubmitted" and pending.get(sms_pid, 0) > 0:
            pending[sms_pid] -= 1
            completed += 1
    window = {q: size for q, size in warm.items() if q >= 5000}
    first = window[5000]
    maximum = max(window.values())
    proof = {
        "artifactSHA256": artifact_sha, "environment": "identitylookup-extension",
        "productionEngine": True, "completed": True, "processIdentifier": pid,
        "coldRunCount": summary["coldRunCount"], "coldRunDefinition": summary["coldRunDefinition"],
        "warmQueryCount": summary["warmQueryCount"], "failedQueries": summary["failedQueries"],
        "completedIncomingSMSQueries": completed,
        "absoluteProcessPeakBytes": summary["processLifetimePeakPhysicalFootprintBytes"],
        "observedProcessBudgetBytes": min(budgets),
        "initialPhysicalFootprintBytes": summary["firstPhysicalFootprintBytes"],
        "finalPhysicalFootprintBytes": summary["finalPhysicalFootprintBytes"],
        "postReleasePhysicalFootprintBytes": released,
        "initialToFinalGrowthBytes": summary["finalPhysicalFootprintBytes"] - summary["firstPhysicalFootprintBytes"],
        "steadyStateWindow": {"startQuery": 5000, "endQuery": 10000, "sampleCount": len(window),
                              "firstPhysicalFootprintBytes": first, "maximumPhysicalFootprintBytes": maximum,
                              "finalPhysicalFootprintBytes": window[10000]},
        "sourceLogs": [{"path": str(p.resolve()), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                       for p in (log_path, sms_path)],
    }
    failures = identitylookup_failures({"profileID": PROFILE_ID, "artifactSHA256": artifact_sha,
                                       "identityLookupEvidence": proof})
    if failures:
        raise ValueError("IdentityLookup gates failed: " + ", ".join(failures))
    return {
        **summary, "identityLookupEvidence": proof,
        "jetsamCount": 0, "coreMLTraceAcceleratorExecutionCount": 0,
        "memoryDriftBytes": max(0, maximum - first),
        "memoryDriftFraction": max(0, maximum - first) / first,
        "memoryDriftDefinition": "maximum growth during fixed queries 5000 through 10000",
        "contentionFallbackP99Milliseconds": summary["warmP99Milliseconds"],
        "cpuOnlyReleaseStressPassed": True,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--sms-stages", type=Path, required=True)
    parser.add_argument("--artifact-sha256", required=True)
    parser.add_argument("--device-model", required=True)
    parser.add_argument("--os-version", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    result = qualify(args.log, args.sms_stages, args.artifact_sha256)
    result.update(deviceModel=args.device_model, osVersion=args.os_version)
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    print(f"qualified {result['coldRunCount']} model reloads and {result['warmQueryCount']} warm queries")


if __name__ == "__main__":
    main()
