import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from import_reviewed_public import digest, materialize, sanitized_text, reviewed_text, filter_coarse_rows, review_template


class ReviewedPublicImportTests(unittest.TestCase):
    def test_v3_typed_locale_materialization_and_excluded_identity_filter(self):
        import csv
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); path=root/'vi.csv'
            texts=['Ma OTP [NUMBER] het han trong [TIME].', 'Gia [MONEY] dong cho nam [NUMBER].']
            with path.open('w') as handle:
                writer=csv.writer(handle);writer.writerow(['label','text'])
                for text in texts:writer.writerow(['0',text])
            manifest={'schemaVersion':3,'profile':'typed-locale-v1','sources':[{
                'id':'vi','file':path.name,'format':'csv','language':'vi',
                'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
                'license':'CC-BY-4.0','licenseEvidence':'https://example.com/license'}], 'reviews':[]}
            for text,label,split,numbers,times in zip(texts,['verification','promotion'],
                    ['train','test'],[['code'],['year']],[['minutes'],[]]):
                review={'source':'vi','key':digest(text),'label':label,'split':split,
                    'language':'vi','reason':'Reviewed typed role, not pseudolabel',
                    'numberRoles':numbers,'timeRoles':times}
                review['sanitizedSHA256']=digest(review_template({'text':text,'language':'vi'},review,3))
                manifest['reviews'].append(review)
            train,test,_=materialize(manifest,root,[])
            self.assertIn('5 phút',train[0]['text'])
            self.assertIn('2026',test[0]['text'])
            self.assertNotIn('$',test[0]['text'])
            self.assertNotIn('VND dong',test[0]['text'])
            self.assertEqual(set(train[0]),{'text','label','source','sourceLabel','language'})
            manifest['reviews'][0].update(label=None,split='exclude',numberRoles=[])
            self.assertEqual(materialize(manifest,root,[])[0],[])
            self.assertEqual(filter_coarse_rows([dict(text=t,label='spam') for t in texts],manifest,root),[])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.texts = ["I left your umbrella in the kitchen. Please collect it after lunch.",
                      "Your customs parcel has arrived; see the existing delivery account."]
        self.path = self.root / "source.csv"
        self.path.write_text("label,message\n" + "".join("ham," + t + "\n" for t in self.texts))
        self.manifest = {"schemaVersion": 1, "sources": [{"id": "source", "file": "source.csv",
            "format": "csv", "sha256": hashlib.sha256(self.path.read_bytes()).hexdigest(),
            "textField": "message", "language": "en", "license": "CC-BY-4.0",
            "licenseEvidence": "https://example.com/license"}], "reviews": [
                {"source": "source", "key": digest(t), "sanitizedSHA256": digest(sanitized_text(t)),
                 "language": "en", "label": label, "split": split, "reason": "Explicit content review"}
                for t, label, split in zip(self.texts, ["__sift_abstain__", "life.express"], ["train", "test"])]}

    def run_import(self, manifest=None, holdouts=None):
        return materialize(manifest or self.manifest, self.root, holdouts or [])

    def test_explicit_labels_and_splits_preserved_without_metadata(self):
        train, test, _ = self.run_import()
        self.assertEqual(train[0]["label"], "__sift_abstain__")
        self.assertEqual(test[0]["label"], "life.express")
        self.assertEqual(set(train[0]), {"text", "label", "language", "source", "sourceLabel"})

    def test_source_checksum_change_fails(self):
        self.path.write_text(self.path.read_text() + "ham,another message\n")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.run_import()

    def test_stale_review_fails(self):
        self.manifest["reviews"][0]["sanitizedSHA256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "sanitizer"):
            self.run_import()

    def test_exact_digit_and_template_holdouts_fail(self):
        for text in [self.texts[0], self.texts[0].upper()]:
            with self.assertRaisesRegex(ValueError, "holdout"):
                self.run_import(holdouts=[text])

    def test_digit_normalized_holdout_and_cross_source_conflict(self):
        text = "Your collection code is 123456 at the north depot today."
        self.texts[0] = text
        self.path.write_text("label,message\n" + "".join("ham," + t + "\n" for t in self.texts))
        self.manifest["sources"][0]["sha256"] = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.manifest["reviews"][0].update(key=digest(text), sanitizedSHA256=digest(sanitized_text(text)))
        with self.assertRaisesRegex(ValueError, "holdout"):
            self.run_import(holdouts=[text.replace("123456", "987654")])
        second = copy.deepcopy(self.manifest["sources"][0])
        second["id"] = "second"
        self.manifest["sources"].append(second)
        review = copy.deepcopy(self.manifest["reviews"][0])
        review.update(source="second", split="test")
        self.manifest["reviews"].append(review)
        with self.assertRaisesRegex(ValueError, "cross-split"):
            self.run_import()

    def test_coarse_labels_cannot_override_reviewed_or_heldout_rows(self):
        base = [{"text": t, "label": "spam"} for t in self.texts]
        kept = {"text": "A separately sourced message that nobody reviewed.", "label": "spam"}
        output = filter_coarse_rows(base + [kept], self.manifest, self.root)
        self.assertEqual(output, [kept])

    def test_cross_split_contributor_or_campaign_fails(self):
        for field in ["campaignGroup", "contributorGroup"]:
            manifest = copy.deepcopy(self.manifest)
            for row in manifest["reviews"]:
                row[field] = "same-group"
            with self.assertRaisesRegex(ValueError, "crosses frozen"):
                self.run_import(manifest)

    def test_unknown_license_and_label_fail(self):
        self.manifest["sources"][0]["license"] = "unknown"
        with self.assertRaisesRegex(ValueError, "provenance"):
            self.run_import()
        self.manifest["sources"][0]["license"] = "CC-BY-4.0"
        self.manifest["reviews"][0]["label"] = "ham"
        with self.assertRaisesRegex(ValueError, "label"):
            self.run_import()

    def test_unreviewed_or_excluded_rows_never_enter_output(self):
        row = self.manifest["reviews"][0]
        row.update(label=None, split="exclude")
        train, test, counts = self.run_import()
        self.assertEqual(train, [])
        self.assertEqual(len(test), 1)
        self.assertEqual(counts["excluded"], 1)
        row["split"] = "train"
        with self.assertRaisesRegex(ValueError, "unlabelled"):
            self.run_import()

    def test_redactions_and_upstream_placeholders(self):
        text = "Alice called 6291628992; see https://example.com/private."
        result = reviewed_text(text, [{"start": 0, "end": 5, "token": "{{NAME}}"}])
        self.assertNotIn("Alice", result)
        self.assertNotIn("6291628992", result)
        self.assertNotIn("private", result)
        self.assertEqual(sanitized_text("Meet in &lt;#&gt; hours"), "Meet in 3 hours")
        self.assertIn("{{PHONE}}", sanitized_text("Call <PHONE_NUMBER> later"))
        with self.assertRaisesRegex(ValueError, "overlapping"):
            reviewed_text(text, [{"start": 0, "end": 6, "token": "{{NAME}}"},
                                 {"start": 3, "end": 9, "token": "{{NAME}}"}])

    def test_v2_square_anonymizers_preserve_v1_and_support_vietnamese(self):
        text = "Ma [NUMBER], so du [MONEY], [BANK_ACC] [PHONE] [NAME] [DATE] [TIME] [POINT]"
        self.assertIn("[MONEY]", reviewed_text(text, []))
        clean = reviewed_text(text, [], square_tokens=True)
        for token in ("{{CODE}}", "{{AMOUNT}}", "{{CARD}}", "{{PHONE}}", "{{NAME}}"):
            self.assertIn(token, clean)
        self.assertNotIn("[DATE]", clean)
        self.manifest["schemaVersion"] = 2
        self.manifest["sources"][0]["language"] = "vi"
        for review in self.manifest["reviews"]:
            review["language"] = "vi"
        train, _, _ = self.run_import()
        self.assertEqual(train[0]["language"], "vi")
        self.assertTrue(train[0]["source"].startswith("public-reviewed-v2:"))

    def test_v2_official_test_source_blocks_even_unselected_test_rows(self):
        self.manifest["schemaVersion"] = 2
        train_source = self.manifest["sources"][0]
        train_source.update(upstreamSplit="train", upstreamTestSource="official-test")
        # The official test file includes the training message, with no selected
        # review for it; selected-test-only isolation would miss the collision.
        test_source = copy.deepcopy(train_source)
        test_source.update(id="official-test", upstreamSplit="test")
        test_source.pop("upstreamTestSource")
        self.manifest["sources"].append(test_source)
        self.manifest["reviews"] = self.manifest["reviews"][:1]
        with self.assertRaisesRegex(ValueError, "official source test family"):
            self.run_import()


if __name__ == "__main__":
    unittest.main()
