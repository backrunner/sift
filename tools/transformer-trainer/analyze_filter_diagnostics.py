#!/usr/bin/env python3
"""Summarize local filter stage logs and Jetsam reports without SMS content."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def read_jsonl(path: Path) -> tuple[list[dict[str, Any]], list[str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    records = []
    warnings = []
    for index, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            if index == len(lines) - 1:
                warnings.append(f"{path.name}: ignored incomplete final record")
                continue
            raise ValueError(f"{path.name}:{index + 1}: invalid JSON") from None
        if not isinstance(value, dict):
            raise ValueError(f"{path.name}:{index + 1}: expected a JSON object")
        records.append(value)
    return records, warnings


def read_jetsam(path: Path) -> list[dict[str, Any]]:
    # Apple .ips reports can contain a header object followed by a second,
    # pretty-printed object; parse JSON boundaries instead of assuming lines.
    content = path.read_text(encoding="utf-8").lstrip()
    decoder = json.JSONDecoder()
    objects = []
    while content:
        value, offset = decoder.raw_decode(content)
        objects.append(value)
        content = content[offset:].lstrip()
    header = objects[0]
    events = []
    for report in objects:
        page_size = report.get("memoryStatus", {}).get("pageSize")
        for process in report.get("processes", []):
            if process.get("name") != "MessageFilterExtension" or not process.get("reason"):
                continue
            pages = process.get("rpages")
            events.append({
                "report": path.name,
                "reportedAt": report.get("date") or header.get("timestamp"),
                "processIdentifier": process.get("pid"),
                "binaryUUID": process.get("uuid"),
                "reason": process["reason"],
                "residentBytes": pages * page_size if pages is not None and page_size else None,
            })
    return events


def summarize(records: list[dict[str, Any]], terminations: list[dict[str, Any]]) -> dict[str, Any]:
    requests: dict[tuple[str, int], list[dict[str, Any]]] = {}
    for record in records:
        if record.get("recordType") not in ("message_filter_stage", "message_filter_event"):
            continue
        request_id = record.get("requestID")
        pid = record.get("processIdentifier")
        if request_id is not None and pid is not None:
            requests.setdefault((request_id, pid), []).append(record)
    summaries = []
    for (request_id, pid), entries in sorted(requests.items()):
        stages = sorted(
            [r for r in entries if r.get("recordType") == "message_filter_stage"],
            key=lambda r: r["elapsedMilliseconds"],
        )
        events = [r for r in entries if r.get("recordType") == "message_filter_event"]
        stage_names = [r["stage"] for r in stages]
        submitted = "responseSubmitted" in stage_names or bool(events)
        watchdog = "watchdogResponded" in stage_names or any(
            r.get("fallbackReason") == "handlerTimedOut" for r in events
        )
        started = "queryReceived" in stage_names
        status = (
            "watchdogResponded" if watchdog else
            "responseSubmitted" if submitted else
            "completionNotObserved" if started else "partialHistory"
        )
        available = [
            r["memory"]["availableMemoryBytes"] for r in stages
            if r.get("memory", {}).get("availableMemoryBytes") is not None
        ]
        last = stages[-1] if stages else {}
        details = events[-1].get("details") or {} if events else {}
        summaries.append({
            "requestID": request_id,
            "processIdentifier": pid,
            "bundleIdentifier": last.get("bundleIdentifier"),
            "appBuild": last.get("appBuild"),
            "requestedArtifactIdentity": last.get("requestedArtifactIdentity"),
            "startedAt": next((r["recordedAt"] for r in stages if r["stage"] == "queryReceived"), None),
            "startObserved": started,
            "status": status,
            "lastStage": last.get("stage"),
            "lastElapsedMilliseconds": last.get("elapsedMilliseconds"),
            "observedFootprintPeakBytes": max(
                (r.get("memory", {}).get("physicalFootprintBytes", 0) for r in stages), default=0
            ),
            "processLifetimePeakBytes": max(
                (r.get("memory", {}).get("processPeakPhysicalFootprintBytes", 0) for r in stages), default=0
            ),
            "minimumReportedAvailableBytes": min(available) if available else None,
            "fallbackReason": events[-1].get("fallbackReason") if events else None,
            "systemAction": details.get("systemAction"),
        })
    return {
        "schemaVersion": 1,
        "requestCount": len(summaries),
        "completionNotObservedCount": sum(r["status"] == "completionNotObserved" for r in summaries),
        "watchdogResponseCount": sum(r["status"] == "watchdogResponded" for r in summaries),
        "extensionTerminationCount": len(terminations),
        "requests": summaries,
        "terminations": terminations,
        "interpretation": [
            "Missing completion can mean termination, truncated/rotated logs, or collection during an active request.",
            "A submitted response does not prove iOS suppressed a notification.",
            "Process lifetime peak includes earlier requests; it is not a per-request peak.",
            "Available memory is a changing process allowance; zero can also mean the API has no applicable limit.",
            "Jetsam termination reasons come from system reports. PID alone is insufficient to correlate across boots.",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--logs", type=Path, nargs="*", default=[])
    parser.add_argument("--jetsam", type=Path, nargs="*", default=[])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.logs and not args.jetsam:
        parser.error("provide --logs or --jetsam")
    records = []
    warnings = []
    for path in args.logs:
        entries, notes = read_jsonl(path)
        records.extend(entries)
        warnings.extend(notes)
    terminations = [event for path in args.jetsam for event in read_jetsam(path)]
    report = summarize(records, terminations)
    report["warnings"] = warnings
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()
