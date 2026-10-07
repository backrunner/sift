import copy
import json
from pathlib import Path
import tempfile
import unittest

from identitylookup_release_gate import PROFILE_ID, identitylookup_failures
from qualify_identitylookup_probe import qualify
from record_device_metrics import merge_device_metrics
from select_quantization_candidate import candidate_failures


class IdentityLookupReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "stress.json"
        self.sms = self.root / "sms.json"
        self.sha = "a" * 64
        self.summary = {
            "artifactSHA256": self.sha, "pid": 100, "coldRunCount": 30,
            "coldRunDefinition": "fresh engine and classifier, same OS process",
            "warmQueryCount": 10000, "failedQueries": 0, "computeUnits": "cpuOnly",
            "environment": "actual IdentityLookup extension; production MessageFilterEngine",
            "processLifetimePeakPhysicalFootprintBytes": 19_900_000,
            "firstPhysicalFootprintBytes": 4_100_000, "finalPhysicalFootprintBytes": 19_100_000,
            "coldP95Milliseconds": 280, "coldP99Milliseconds": 383,
            "coldMaximumMilliseconds": 383, "warmP95Milliseconds": 138, "warmP99Milliseconds": 171,
        }
        self.records = [{"subsystem": "com.alkinum.sift.phaseprobe.filter",
                         "eventMessage": "qualificationSummary=" + json.dumps(self.summary)}]
        stages = [f"engineColdReload{q}Finished" for q in range(1, 31)]
        stages += [f"engineWarm{q}Finished" for q in range(100, 10001, 100)]
        stages += ["qualificationCompleted"]
        self.records += [{"subsystem": "com.alkinum.sift.phaseprobe.filter", "eventMessage":
                         f"candidate=full12Legacy32 pid=100 stage={s} footprint=19100000 process_peak=19900000 available=6060000"}
                         for s in stages]
        self.sms.write_text(json.dumps([{"eventMessage": f"candidate=full12Legacy32 pid=99 stage={s} "}
                                       for s in ("queryReceived", "responseSubmitted")]))

    def evidence(self):
        self.log.write_text(json.dumps(self.records))
        result = qualify(self.log, self.sms, self.sha)
        result.update(deviceModel="test-iPhone", osVersion="test-os")
        return result

    def test_complete_probe_preserves_initial_growth_and_separate_steady_window(self):
        evidence = self.evidence()
        proof = evidence["identityLookupEvidence"]
        self.assertEqual(proof["initialToFinalGrowthBytes"], 15_000_000)
        self.assertEqual(evidence["memoryDriftBytes"], 0)
        self.assertEqual(proof["steadyStateWindow"]["sampleCount"], 51)
        self.assertEqual(proof["completedIncomingSMSQueries"], 1)
        self.assertEqual(len(proof["sourceLogs"]), 2)

    def test_missing_checkpoint_is_rejected(self):
        self.records.pop(40)
        with self.assertRaisesRegex(ValueError, "incomplete"):
            self.evidence()

    def test_summary_cannot_understate_logged_peak(self):
        self.records[1]["eventMessage"] = self.records[1]["eventMessage"].replace(
            "process_peak=19900000", "process_peak=23000000")
        with self.assertRaisesRegex(ValueError, "contradicts measured"):
            self.evidence()

    def test_unmatched_incoming_response_is_rejected(self):
        self.sms.write_text(json.dumps([
            {"eventMessage": "candidate=full12Legacy32 pid=99 stage=queryReceived "},
            {"eventMessage": "candidate=full12Legacy32 pid=98 stage=responseSubmitted "},
        ]))
        with self.assertRaisesRegex(ValueError, "identityLookupActualSMS"):
            self.evidence()

    def test_absolute_peak_headroom_drift_and_artifact_are_independent_gates(self):
        proof = self.evidence()["identityLookupEvidence"]
        mutations = [
            ({"absoluteProcessPeakBytes": 22 * 1024 * 1024}, "identityLookupAbsoluteMemory"),
            ({"observedProcessBudgetBytes": 21_000_000}, "identityLookupHeadroom"),
            ({"artifactSHA256": "b" * 64}, "identityLookupArtifact"),
            ({"failedQueries": 1}, "identityLookupCompletion"),
            ({"warmQueryCount": 9999}, "identityLookupRunCounts"),
            ({"steadyStateWindow": {**proof["steadyStateWindow"],
                                   "maximumPhysicalFootprintBytes": 22_000_000}}, "identityLookupMemoryDrift"),
        ]
        for changes, expected in mutations:
            with self.subTest(expected=expected):
                report = {"profileID": PROFILE_ID, "artifactSHA256": self.sha,
                          "identityLookupEvidence": {**proof, **changes}}
                self.assertIn(expected, identitylookup_failures(report))

    def test_skip_device_evidence_does_not_bypass_new_profile_extension_gate(self):
        report = {"profileID": PROFILE_ID, "artifactSHA256": self.sha}
        self.assertIn("identityLookupCompletion", candidate_failures(report, {}, skip_device_evidence=True))

    def test_merge_binds_host_and_extension_to_same_artifact(self):
        evidence = self.evidence()
        benchmark = {"artifactIdentity": {"sha256": self.sha}, "computeUnits": "cpuOnly",
                     "deviceModel": "test-iPhone", "computePlan": {"neuralNetworkLayerCount": 641,
                     "deviceAssignedLayerCount": 561, "cpuPreferredLayerCount": 561}}
        report = {"profileID": PROFILE_ID, "artifactSHA256": self.sha}
        merged = merge_device_metrics(report, benchmark, evidence)
        self.assertEqual(merged["identityLookupEvidence"], evidence["identityLookupEvidence"])
        self.assertTrue(merged["deviceMetrics"]["runtimeExecutionVerified"])
        mismatched = copy.deepcopy(benchmark)
        mismatched["artifactIdentity"]["sha256"] = "b" * 64
        with self.assertRaisesRegex(SystemExit, "artifact does not match"):
            merge_device_metrics(report, mismatched, evidence)


if __name__ == "__main__":
    unittest.main()
