import copy
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fusion_v68 import loss, select, eligible
from author_fusion_v68 import cases


def metric(epoch=0):
    m=dict(actionCorrect=66, scored=72, policyActionAccuracy=66/72, harmfulCaught=17, harmfulRecall=17/18,
           commercialCaught=17, normalToJunk=0, normalToPromotion=0)
    return dict(epoch=epoch, policy=m, byLanguage={k: copy.deepcopy(m) for k in ('zh','en','ja')},
                protectedFineChanges=0, junkDowngrades=0)


class FusionTests(unittest.TestCase):
    def test_new_roles_have_complete_grouped_translations_and_shared_urls(self):
        family=set(); domains=set(); roles={'calibration':0,'validation':0}
        for role, name, label, host, variants in cases():
            self.assertNotIn(name,family);family.add(name);self.assertNotIn(host,domains);domains.add(host)
            roles[role]+=1;self.assertEqual(len(variants),4)
            for translations in variants:
                self.assertEqual(len(translations),3)
                for text in translations:self.assertNotIn('://',text)
        self.assertEqual(roles,{'calibration':6,'validation':6})

    def test_cost_penalizes_filtering_normal_without_changing_harm_or_commercial(self):
        import torch
        x=torch.tensor([[0.,0.,1.,3.]]*4,requires_grad=True);y=torch.tensor([0,1,2,3])
        original=loss(x,y,0); costly=loss(x,y,2)
        self.assertTrue(torch.all(costly[:2]>original[:2]))
        self.assertTrue(torch.equal(costly[2:],original[2:]))
        costly.sum().backward();self.assertTrue(torch.isfinite(x.grad).all())
        with self.assertRaises(ValueError):loss(x,y,4)

    def test_epoch_selection_preserves_protection_and_language_recall(self):
        records=[metric(e) for e in range(19)]
        self.assertEqual(select(records)['epoch'],0)
        records[4]['policy']['actionCorrect']=67
        records[4]['policy']['policyActionAccuracy']=67/72
        self.assertEqual(select(records)['epoch'],4)
        records[5]['policy']['actionCorrect']=70
        records[5]['byLanguage']['ja']['normalToJunk']=1
        self.assertEqual(select(records)['epoch'],4)
        records[4]['byLanguage']['zh']['harmfulCaught']-=1
        self.assertEqual(select(records)['epoch'],0)

    def test_fine_leaf_preservation_and_junk_downgrade_are_hard_gates(self):
        b=metric();c=metric(1);c['protectedFineChanges']=1
        self.assertFalse(eligible(c,b));c['protectedFineChanges']=0;c['junkDowngrades']=1
        self.assertFalse(eligible(c,b))
        with self.assertRaises(ValueError):select([b,c])


if __name__ == '__main__':unittest.main()
