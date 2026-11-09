import copy
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from expert_routing_v71 import folds,features,targets,safety,select
from author_routing_v71 import cases


class ExpertRoutingTests(unittest.TestCase):
    def test_fold_never_splits_a_family_or_translation(self):
        rows=[dict(familyId=f'{src}{n}',source=f'authored-reviewed-{src}:test',language=lang)
              for src in ('v66','v69') for n in range(6) for lang in ('zh','en','ja') for _ in range(4)]
        split=folds(rows)
        self.assertEqual([split.count(k) for k in range(3)],[48]*3)
        for family in {r['familyId'] for r in rows}:self.assertEqual(len({f for r,f in zip(rows,split) if r['familyId']==family}),1)
        with self.assertRaises(ValueError):folds(rows[:-1])

    def test_features_are_finite_and_distinguish_leaf_from_business_mass(self):
        import torch
        full=[{'probabilities':{'a':.3,'b':.3,'spam':.4,'none':0.,'promo':0.}}]
        head=[dict(business=.01,ordinary=.98,commercial=.005,harmful=.005)]
        x=features(full,head,{'a':'transaction','b':'transaction','spam':'junk','none':'none','promo':'promotion'})
        self.assertEqual(tuple(x.shape),(1,18));self.assertTrue(torch.isfinite(x).all())
        self.assertAlmostEqual(x[0,0].item(),.6,places=6)
        self.assertEqual(x[0,-1].item(),1)

    def test_targets_penalize_filtering_and_keep_ties_on_fine(self):
        r=[{'label':'business','filterReview':{'kind':'normal'}}]*3
        f=[{'engineAction':a} for a in ('junk','transaction','transaction')]
        h=[{'engineAction':a} for a in ('transaction','junk','transaction')]
        y,w=targets(r,f,h,{'business':'transaction'})
        self.assertEqual(y.tolist(),[1.,0.,0.]);self.assertEqual(w[:2].tolist(),[5.,5.])
        self.assertAlmostEqual(w[2].item(),.1,places=6)

    def test_no_recall_exchange_and_no_sample_count_drift(self):
        p=dict(actionCorrect=66,scored=72,normalToJunk=0,normalToPromotion=0,policyActionAccuracy=66/72,harmfulCaught=18,harmfulRecall=1.,commercialCaught=18)
        b=dict(epoch=0,policy=p,byLanguage={'ja':copy.deepcopy(p)},harmfulLost=0,normalNewJunk=0,normalNewPromotion=0)
        c=copy.deepcopy(b);c['harmfulLost']=1;self.assertFalse(safety(c,b))
        r=[{**copy.deepcopy(b),'epoch':e} for e in range(19)];self.assertEqual(select(r)['epoch'],0)
        r[6]['policy']['actionCorrect']=67;self.assertEqual(select(r)['epoch'],6)
        with self.assertRaises(ValueError):select(r[:-1])

    def test_authored_calibration_is_six_complete_families(self):
        self.assertEqual(len(cases()),6)
        for family,label,host,variants in cases():
            self.assertEqual(len(variants),4)
            self.assertTrue(all(len(t)==3 for t in variants))
            self.assertTrue(all('://' not in s for t in variants for s in t))


if __name__=='__main__':unittest.main()
