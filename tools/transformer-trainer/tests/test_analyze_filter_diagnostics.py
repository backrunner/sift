import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "analyze_filter_diagnostics", Path(__file__).resolve().parents[1] / "analyze_filter_diagnostics.py"
)
analyzer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analyzer)


def stage(request, name, elapsed, **kwargs):
    return {
        "recordType": "message_filter_stage", "requestID": request,
        "processIdentifier": 123, "stage": name, "elapsedMilliseconds": elapsed,
        "recordedAt": "2026-09-05T10:00:00Z",
        "memory": {"physicalFootprintBytes": 10, "processPeakPhysicalFootprintBytes": 20},
        **kwargs,
    }


class FilterDiagnosticTests(unittest.TestCase):
    def test_interleaved_requests_do_not_share_completion(self):
        report = analyzer.summarize([
            stage("a", "queryReceived", 0), stage("b", "queryReceived", 0),
            stage("a", "modelLoadStarted", 2), stage("b", "responseSubmitted", 4),
        ], [])
        self.assertEqual(report["completionNotObservedCount"], 1)
        self.assertEqual(report["extensionTerminationCount"], 0)
        self.assertEqual(report["requests"][0]["lastStage"], "modelLoadStarted")
        self.assertEqual(report["requests"][1]["status"], "responseSubmitted")
        self.assertEqual(report["requests"][0]["processLifetimePeakBytes"], 20)

    def test_late_prediction_does_not_hide_watchdog(self):
        report = analyzer.summarize([
            stage("a", "queryReceived", 0), stage("a", "watchdogResponded", 6000),
            stage("a", "signalInferenceFinished", 8000),
        ], [])
        self.assertEqual(report["watchdogResponseCount"], 1)
        self.assertEqual(report["completionNotObservedCount"], 0)

    def test_completed_event_survives_stage_rotation_and_omits_message_fields(self):
        report = analyzer.summarize([{
            "recordType": "message_filter_event", "requestID": "a", "processIdentifier": 123,
            "fallbackReason": "none", "details": {"systemAction": "promotion", "body": "secret"},
        }, stage("b", "predictionStarted", 1)], [])
        self.assertEqual(report["requests"][0]["status"], "responseSubmitted")
        self.assertEqual(report["requests"][0]["systemAction"], "promotion")
        self.assertEqual(report["requests"][1]["status"], "partialHistory")
        self.assertNotIn("secret", json.dumps(report))

    def test_jetsam_uses_reason_and_page_size_not_largest_process(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.ips"
            header = {"timestamp": "2026-09-03 13:18:32 +0800"}
            report = {"memoryStatus": {"pageSize": 16384}, "largestProcess": "Unrelated", "processes": [
                {"name": "MessageFilterExtension", "pid": 1, "rpages": 1536, "reason": "per-process-limit"},
                {"name": "MessageFilterExtension", "pid": 2, "rpages": 1536, "reason": "per-process-limit"},
                {"name": "MessageFilterExtension", "pid": 3, "rpages": 50},
                {"name": "Unrelated", "pid": 4, "rpages": 9000, "reason": "vm-pageshortage"},
            ]}
            path.write_text(json.dumps(header) + "\n" + json.dumps(report, indent=2))
            result = analyzer.read_jetsam(path)
            self.assertEqual(len(result), 2)
            self.assertEqual(result[0]["residentBytes"], 24 * 1024 * 1024)

    def test_only_truncated_final_jsonl_record_is_tolerated(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "filter.jsonl"
            path.write_text(json.dumps(stage("a", "queryReceived", 0)) + '\n{"recordType":')
            records, warnings = analyzer.read_jsonl(path)
            self.assertEqual(len(records), 1)
            self.assertEqual(len(warnings), 1)
            path.write_text('{bad}\n{}\n')
            with self.assertRaises(ValueError):
                analyzer.read_jsonl(path)


if __name__ == "__main__":
    unittest.main()
