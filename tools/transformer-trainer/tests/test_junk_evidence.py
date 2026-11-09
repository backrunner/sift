import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from junk_evidence import text_sha,validate_junk_evidence,validate_profile_input


class JunkEvidenceTests(unittest.TestCase):
    def fixture(self):
        row={'text':'Account notice: visit https://brand-login.invalid/verify','label':'spam','source':'reviewed-source'}
        host='brand-login.invalid';a=row['text'].index(host)
        review={'schemaVersion':1,'maxLength':96,'sourceEvidence':{'research':{'file':'source.txt','sha256':'abc'}},
            'decisions':[{'textSHA256':text_sha(row['text']),'decision':'retain','source':row['source'],
                'evidenceKind':'domain','visibleCharacterEnd':len(row['text']),
                'supportSpans':[[a,a+len(host)]],'requiredHosts':[host],'sourceEvidenceKey':'research'}]}
        return row,review

    def test_visible_domain_evidence_passes(self):
        row,review=self.fixture()
        self.assertEqual(validate_junk_evidence([row],review)['domainEvidence'],1)

    def test_removed_hostname_cannot_inherit_junk_gold(self):
        row,review=self.fixture();row['text']='Account notice: visit {{URL}}'
        with self.assertRaisesRegex(ValueError,'lacks accepted'):validate_junk_evidence([row],review)
        review['decisions'][0]['textSHA256']=text_sha(row['text'])
        review['decisions'][0]['visibleCharacterEnd']=len(row['text'])
        review['decisions'][0]['supportSpans']=[[0,len(row['text'])]]
        with self.assertRaisesRegex(ValueError,'removed or truncated'):validate_junk_evidence([row],review)

    def test_evidence_outside_token_window_is_rejected(self):
        row,review=self.fixture();review['decisions'][0]['visibleCharacterEnd']=20
        with self.assertRaisesRegex(ValueError,'absent from'):validate_junk_evidence([row],review)

    def test_unknown_source_cannot_supply_domain_gold(self):
        row,review=self.fixture();review['sourceEvidence']={}
        with self.assertRaisesRegex(ValueError,'source evidence'):validate_junk_evidence([row],review)

    def test_unknown_junk_row_requires_review(self):
        row,review=self.fixture();review['decisions']=[]
        with self.assertRaisesRegex(ValueError,'lacks accepted'):validate_junk_evidence([row],review)

    def test_quarantine_is_not_a_normal_label(self):
        row,review=self.fixture();review['decisions'][0]['decision']='exclude';row['label']='transaction.account_security'
        with self.assertRaisesRegex(ValueError,'reintroduced'):validate_junk_evidence([row],review)

    def test_nonjunk_warning_is_not_automatically_relabelled(self):
        row={'text':'Do not send your password to anyone.','label':'transaction.account_security','source':'reviewed'}
        _,review=self.fixture()
        self.assertEqual(validate_junk_evidence([row],review)['bodyEvidence'],0)

    def test_lower_input_budget_requires_fresh_review(self):
        corpus={'junkEvidenceReview':'review.json','junkEvidenceTokenizerSHA256':{'tokenizer.json':'abc'}}
        validate_profile_input(corpus,['--max-length','96'],{'filesSHA256':{'tokenizer.json':'abc'}})
        with self.assertRaisesRegex(ValueError,'re-audit'):validate_profile_input(corpus,['--max-length','64'])

    def test_tokenizer_change_requires_rechecking_visible_evidence(self):
        corpus={'junkEvidenceReview':'review.json','junkEvidenceTokenizerSHA256':{'tokenizer.json':'abc'}}
        with self.assertRaisesRegex(ValueError,'tokenizer changed'):
            validate_profile_input(corpus,['--max-length','96'],{'filesSHA256':{'tokenizer.json':'def'}})

    def test_duplicate_or_source_changed_review_rejected(self):
        row,review=self.fixture();review['decisions'].append(copy.deepcopy(review['decisions'][0]))
        with self.assertRaisesRegex(ValueError,'duplicate'):validate_junk_evidence([row],review)
        row,review=self.fixture();row['source']='unreviewed-source'
        with self.assertRaisesRegex(ValueError,'source drift'):validate_junk_evidence([row],review)
