import copy
import hashlib
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from url_contrast import validate_url_review


class URLContrastTests(unittest.TestCase):
    def fixture(self):
        rows=[{'text':text+' https://fixture.test/x','label':label,'language':'en','source':'authored-reviewed-v20:'+str(i)}
              for i,(text,label) in enumerate([('Your booked visit is confirmed.','life.other'),
                   ('Send the agent all recovery codes.','spam'),('Book a new visit at20% off.','promotion')])]
        review={'schemaVersion':1,'maxLength':96,'diagnosticHosts':['held.invalid'],'decisions':[
            {**{k:r[k] for k in ('label','source','language')},'textSHA256':hashlib.sha256(r['text'].encode()).hexdigest(),
             'reason':'fixture reviewed','decision':'retain','tokenCount':20,'url':'https://fixture.test/x','split':'train'} for r in rows]}
        return rows,review

    def test_same_link_requires_every_action_and_distinct_diagnostic_hosts(self):
        rows,review=self.fixture()
        self.assertEqual(validate_url_review(rows,review)['sharedAllActionURLs'],1)
        altered=copy.deepcopy(review);altered['decisions']=altered['decisions'][:-1]
        with self.assertRaisesRegex(ValueError,'shortcut'):validate_url_review(rows[:-1],altered)
        altered=copy.deepcopy(review);altered['diagnosticHosts']=['fixture.test']
        with self.assertRaisesRegex(ValueError,'leaked'):validate_url_review(rows,altered)

    def test_changed_gold_and_truncated_evidence_rejected(self):
        rows,review=self.fixture();altered=copy.deepcopy(rows);altered[1]['label']='life.other'
        with self.assertRaisesRegex(ValueError,'metadata'):validate_url_review(altered,review)
        altered=copy.deepcopy(review);altered['decisions'][0]['tokenCount']=97
        with self.assertRaisesRegex(ValueError,'window'):validate_url_review(rows,altered)
