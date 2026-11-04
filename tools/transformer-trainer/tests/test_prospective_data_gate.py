import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prospective_data_gate import audit, require_ready, verify_profile_contract


class ProspectiveDataGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.sources = []
        self.data = {}
        examples = {
            "train": [("spam", "Buy stolen payment accounts with passwords from this dealer."),
                      ("promotion", "Spring footwear sale: sandals and boots are half price this weekend."),
                      ("life.medical", "Your dental follow-up is booked for Tuesday at the clinic.")],
            "development": [("spam", "Send your bank PIN to my private inbox to prevent account deletion."),
                            ("promotion", "Garden furniture clearance starts tomorrow; browse our catalogue."),
                            ("life.medical", "The laboratory has received your blood sample and will notify you of results.")],
            "calibration": [("spam", "Transfer cryptocurrency to my personal wallet before we release your inheritance."),
                            ("promotion", "Try our new coffee subscription with a discount on the first delivery."),
                            ("life.medical", "An earlier physiotherapy appointment has become available. Call reception to reschedule.")],
            "final": [("spam", "This police warrant can only be cancelled by sending shopping gift-card redemption codes."),
                      ("promotion", "Tickets for the summer music festival are now on sale at the box office."),
                      ("life.medical", "Your prescription has been dispensed; collect the medication from the pharmacy.")],
        }
        evidence = self.write("evidence.txt", "Test fixture; no real provenance claim.")
        for role, pairs in examples.items():
            self.sources.append({"id": role, "lineageId": role, "role": role,
                "kind": "observed_sms", "commercialReuseReviewed": True, "previouslyUsed": False,
                "provenanceEvidence": evidence, "licenseEvidence": evidence})
            self.data[role] = [{"text": text, "label": label, "language": "en", "sourceId": role,
                "originalId": f"{role}-{i}", "familyId": f"{role}-{i}", "predictionSeen": False,
                "acquisitionKind": "observed_sms", "isTranslated": False, "isSynthetic": False,
                "goldReview": {"status": "accepted", "withoutModelPredictions": True,
                    "reviewerRole": "test-fixture", "reason": "Explicit fixture label.",
                    "junkEvidence": {"kind": "body", "clause": text} if label == "spam" else {}}}
                for i, (label, text) in enumerate(pairs)]
        self.plan = {"schemaVersion": 1, "reviewStatus": "sealed", "finalAlreadyScored": False,
            "publicSuffixes": self.write("suffix.dat", "com\norg\nnet\n"),
            "taxonomy": self.write("taxonomy.json", {"groups": [
                {"systemAction": "junk", "leaves": [{"id": "spam"}]},
                {"systemAction": "promotion", "leaves": [{"id": "promotion"}]},
                {"systemAction": "transaction", "leaves": [{"id": "life.medical"}]}]}),
            "baseTraining": self.write_rows("base.ndjson", [{"text": "Meal preparation instructions for a vegetable casserole.",
                "label": "life.medical", "language": "en"}]),
            "historicalExclusions": [self.write_rows("old.ndjson", [{"text": "A historical protected evaluation sentence about collecting library books."}])],
            "minimumCounts": {role: {"en": {"junk": 1, "promotion": 1, "nonpromotion": 1}}
                              for role in examples}}
        self.seal()

    def write(self, name, value):
        path = self.root / name
        path.write_text(value if isinstance(value, str) else json.dumps(value))
        return {"path": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

    def write_rows(self, name, values):
        return self.write(name, "".join(json.dumps(x) + "\n" for x in values))

    def seal(self):
        self.plan["sources"] = self.write("sources.json", self.sources)
        self.plan["datasets"] = {role: self.write_rows(role + ".ndjson", values)
                                 for role, values in self.data.items()}
        self.write("plan.json", self.plan)

    def rejected(self, needle):
        result = audit(self.plan, self.root)
        self.assertFalse(result["trainingReady"])
        self.assertTrue(any(needle in e for e in result["errors"]), result["errors"])

    def test_complete_disjoint_fixture_passes_without_release_claim(self):
        result = audit(self.plan, self.root)
        self.assertEqual(result["errors"], [])
        self.assertTrue(result["trainingReady"])
        self.assertFalse(result["releaseEligible"])

    def test_missing_or_empty_final_fails(self):
        self.plan["datasets"].pop("final")
        self.rejected("final: dataset not collected")
        self.data["final"] = []
        self.seal()
        self.rejected("final: empty dataset")

    def test_templates_and_translations_are_train_only(self):
        for kind in ("official_template", "synthetic", "translated"):
            self.sources[0]["kind"] = kind
            for row in self.data["train"]:
                row["acquisitionKind"] = kind
            self.seal()
            self.assertTrue(audit(self.plan, self.root)["trainingReady"])
            self.sources[3]["kind"] = kind
            self.seal()
            self.rejected("non-observed SMS")
            self.sources[3]["kind"] = "observed_sms"

    def test_mirror_lineage_and_translation_parent_bridge_are_detected(self):
        self.sources[3]["lineageId"] = "train"
        self.seal()
        self.rejected("cross-role connected")
        self.sources[3]["lineageId"] = "final"
        self.data["final"][0]["parentOriginalId"] = "train-0"
        self.seal()
        self.rejected("cross-role connected")

    def test_digit_changed_or_host_changed_copy_stays_same_family(self):
        a = "Parcel tracking code 12345 has arrived at https://carrier.com/check"
        b = "Parcel tracking code 98621 has arrived at https://different.org/other"
        self.data["train"][2]["text"] = a
        self.data["final"][2]["text"] = b
        self.seal()
        self.rejected("cross-role connected")

    def test_historical_and_base_overlap_fail(self):
        for spec in [self.plan["baseTraining"], *self.plan["historicalExclusions"]]:
            text = json.loads((self.root / spec["path"]).read_text().splitlines()[0])["text"]
            self.data["final"][2]["text"] = text
            self.seal()
            self.rejected("overlaps historical")

    def test_shared_destination_connects_different_bodies(self):
        self.data["train"][2]["text"] += " More at https://clinic.example.com/book"
        self.data["final"][2]["text"] += " Details: https://portal.example.com/medicine"
        self.seal()
        self.rejected("cross-role connected")

    def test_gold_cannot_come_from_predictions_or_unsupported_junk(self):
        self.data["development"][0]["goldReview"]["withoutModelPredictions"] = False
        self.seal()
        self.rejected("not blindly reviewed")
        self.data["development"][0]["goldReview"]["withoutModelPredictions"] = True
        self.data["development"][0]["goldReview"]["junkEvidence"]["clause"] = "not actually in the input"
        self.seal()
        self.rejected("junk clause absent")

    def test_unknown_provenance_and_unreviewed_reuse_fail(self):
        self.sources[0]["kind"] = "unknown"
        self.sources[0]["commercialReuseReviewed"] = False
        self.seal()
        self.rejected("unresolved acquisition")
        self.rejected("reuse unresolved")

    def test_spent_or_exposure_unknown_final_fails(self):
        self.plan["finalAlreadyScored"] = True
        self.rejected("final exposure")
        self.plan["finalAlreadyScored"] = False
        del self.data["final"][1]["predictionSeen"]
        self.seal()
        self.rejected("prior exposure")

    def test_translated_row_cannot_hide_in_observed_source(self):
        self.data["final"][1]["isTranslated"] = True
        self.seal()
        self.rejected("synthetic/translation status")

    def test_native_training_minimum_cannot_be_filled_by_translations(self):
        self.plan["minimumObservedTrainingCounts"] = {"en": 3}
        self.data["train"][0]["isTranslated"] = True
        self.seal()
        self.rejected("native-observed: 2 < 3")

    def test_source_role_cannot_be_changed_by_row(self):
        self.data["development"][1]["sourceId"] = "train"
        self.seal()
        self.rejected("source role differs")

    def test_hash_drift_and_outside_root_fail_closed(self):
        (self.root / "evidence.txt").write_text("changed")
        with self.assertRaisesRegex(ValueError, "pinned input"):
            audit(self.plan, self.root)

    def test_actual_runner_corpus_must_equal_registered_base_plus_additions(self):
        self.write_rows("combined.ndjson", [json.loads((self.root / "base.ndjson").read_text()), *self.data["train"]])
        profile = {"prospectiveDataPlan": "plan.json",
                   "prospectiveDataPlanSHA256": hashlib.sha256((self.root / "plan.json").read_bytes()).hexdigest()}
        corpus = {"training": "combined.ndjson", "development": "development.ndjson"}
        self.assertTrue(verify_profile_contract(profile, corpus, self.root)["trainingReady"])
        (self.root / "combined.ndjson").write_text((self.root / "base.ndjson").read_text())
        with self.assertRaisesRegex(ValueError, "training rows differ"):
            verify_profile_contract(profile, corpus, self.root)

    def test_collecting_plan_cannot_launch_training(self):
        self.plan["reviewStatus"] = "collecting"
        self.seal()
        with self.assertRaisesRegex(ValueError, "not ready"):
            require_ready(self.root / "plan.json", self.root)

    def test_historical_profiles_keep_existing_contract(self):
        self.assertIsNone(verify_profile_contract({}, {}, self.root))


if __name__ == "__main__":
    unittest.main()
