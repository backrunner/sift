import copy
from pathlib import Path
import sys
import tempfile
import json
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from reviewed_weights import build_spec,validate,row_weight


class ReviewedWeightsTests(unittest.TestCase):
    def test_bounded_mass_keeps_both_sides_and_all_roots(self):
        rows=[{'text':str(i),'label':l,'language':lang} for i,(l,lang) in enumerate([
            ('spam','zh'),('spam','ja'),('spam','en'),('spam','vi'),('promotion','en'),
            ('__sift_abstain__','en'),('__sift_abstain__','ja'),('finance.bank','zh')])]
        spec=build_spec(rows,'hash');validate(rows,spec)
        self.assertEqual(len(spec['entries']),len(rows));self.assertEqual(spec['range'],[.65,2.])
        self.assertAlmostEqual(sum(spec['weightedActionFractions'].values()),1.)
        self.assertEqual(row_weight(rows[-1]),1.)
        self.assertEqual(row_weight(rows[4]),1.2)
    def test_membership_gold_and_infinite_weights_are_rejected(self):
        rows=[{'text':'one','label':'spam','language':'ja'}];spec=build_spec(rows,'hash')
        for change in ('label','weight','membership'):
            bad=copy.deepcopy(spec);entry=next(iter(bad['entries'].values()))
            if change=='label':entry['label']='promotion'
            if change=='weight':entry['weight']=float('inf')
            if change=='membership':bad['entries'].clear()
            with self.assertRaises(ValueError):validate(rows,bad)
    def test_real_collate_applies_weights_and_uniform_control_is_exact(self):
        import torch
        import train_mmbert as train
        from reviewed_weights import install
        rows=[{'text':'junk','label':'spam','language':'ja'},{'text':'chat','label':'__sift_abstain__','language':'en'}]
        spec=build_spec(rows,'hash');items=[{**r,'label':i,'source':'base'} for i,r in enumerate(rows)]
        tokenize=lambda texts,**kw:{'input_ids':torch.ones((len(texts),2),dtype=torch.long)}
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'weights.json';p.write_text(json.dumps(spec))
            for enabled,expected in ((False,[1.,1.]),(True,[2.,.65])):
                old=install(p,enabled)
                try:result=train.make_collate(tokenize,2)(items)
                finally:train.make_collate=old
                torch.testing.assert_close(result['loss_weights'],torch.tensor(expected))
