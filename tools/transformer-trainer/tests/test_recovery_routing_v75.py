import sys
from pathlib import Path
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from recovery_routing_v75 import BRANCHES,folds,gate,objective,preferences,select


class RecoveryRoutingTests(unittest.TestCase):
    def test_family_roles_and_translations_stay_together(self):
        rows=[]
        for version,n in ((66,6),(69,6),(75,18)):
            for group in range(n):
                rows += [dict(familyId=f'{version}-{group}',source=f'authored-reviewed-v{version}:x',language=lang)
                         for _ in range(4) for lang in ('zh','en','ja')]
        f=folds(rows)
        self.assertEqual([f.count(i) for i in range(3)],[120]*3)
        for group in {r['familyId'] for r in rows}:
            self.assertEqual(len({v for r,v in zip(rows,f) if r['familyId']==group}),1)
        with self.assertRaises(ValueError):folds(rows[:-1])

    def test_opposite_directions_do_not_share_risk_labels(self):
        import torch
        g=gate('data-directional',321)
        x=torch.ones(3,18);y=torch.ones(3);w=torch.ones(3)
        objective(g,x,y,w,torch.zeros(3,dtype=torch.long)).backward()
        self.assertLess(float(g.bias.grad[0]),0)
        self.assertEqual(g.bias.grad[1:].tolist(),[0.,0.])
        self.assertTrue(torch.equal(g.weight.grad[1:],torch.zeros_like(g.weight.grad[1:])))

    def test_uncertain_initialization_keeps_sam_and_mlp_is_reproducible(self):
        import torch
        for arm,width,count in (('data-joint',18,19),('data-directional',18,57),('semantic-linear',402,1209),('semantic-mlp',402,12995)):
            g=gate(arm,321);p=preferences(g,torch.randn(4,width))
            self.assertEqual(sum(v.numel() for v in g.parameters()),count)
            self.assertTrue(all(set(r)==set(BRANCHES) and all(v<.5 for v in r.values()) for r in p))
            self.assertTrue(all(torch.equal(v,gate(arm,321).state_dict()[k]) for k,v in g.state_dict().items()))

    def test_checkpoint_selection_cannot_waive_false_blocks_for_accuracy(self):
        base=dict(policy=dict(actionCorrect=90,scored=100,policyActionAccuracy=.9,normalToJunk=1,normalToPromotion=0,harmfulCaught=20,harmfulRecall=1),
                  byLanguage={'en':dict(harmfulCaught=20,commercialCaught=20)},harmfulLost=0,normalNewJunk=0,normalNewPromotion=0)
        records=[dict(base,epoch=0)]
        for epoch in range(1,37):
            records.append(dict(base,epoch=epoch,normalNewJunk=1,policy=dict(base['policy'],actionCorrect=99,policyActionAccuracy=.99)))
        self.assertEqual(select(records)['epoch'],0)
        records[7]=dict(base,epoch=7,policy=dict(base['policy'],actionCorrect=98,policyActionAccuracy=.98))
        self.assertEqual(select(records)['epoch'],7)


if __name__=='__main__':unittest.main()
