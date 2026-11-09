import importlib.util
from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from spam_objective import positive_weight


class WeightTests(unittest.TestCase):
    def test_training_prior_is_bounded(self):
        self.assertEqual(positive_weight([0,1],1),1.)
        self.assertEqual(positive_weight([0]*100+[1],1),3.)
        with self.assertRaises(ValueError):positive_weight([1,1],1)

    def test_explicit_equal_cost_does_not_apply_training_prior(self):
        self.assertEqual(positive_weight([0]*100+[1],1,1.),1.)
        for invalid in (0.,-1.,float('nan'),float('inf')):
            with self.assertRaises(ValueError):positive_weight([0,1],1,invalid)


@unittest.skipUnless(importlib.util.find_spec('torch'),'requires torch')
class SpamObjectiveTests(unittest.TestCase):
    def test_training_uses_explicit_cost_and_records_it(self):
        import torch
        from types import SimpleNamespace
        from train_mmbert import train_model
        class Tiny(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.linear=torch.nn.Linear(1,2)
            def forward(self,input_ids):
                return SimpleNamespace(logits=self.linear(input_ids))
        rows=[dict(text=str(i+1),label='spam' if i==0 else 'normal',source='reviewed') for i in range(4)]
        args=SimpleNamespace(num_epochs=1,seed=7,max_length=2,boundary_loss_weight=1.,train_label_rows=[],
            selected_label_loss_weight=1.,batch_size=4,learning_rate=.001,weight_decay=0.,
            label_smoothing=0.,warmup_ratio=0.,early_stopping_patience=0,
            spam_loss_weight=.2,spam_positive_weight=1.)
        summary={}
        train_model(Tiny(),lambda texts,**kw:{'input_ids':torch.tensor([[float(t)] for t in texts])},
            rows,{'normal':0,'spam':1},args,'cpu',optimization_summary=summary)
        self.assertEqual(summary['spamObjective'],dict(weight=.2,positiveWeight=1.,trainingPositiveCount=1,trainingNegativeCount=3))

    def test_matches_weighted_log_probability_reference(self):
        import torch
        from spam_objective import spam_binary_loss
        logits=torch.tensor([[1.,2.,3.],[3.,1.,2.]],requires_grad=True);labels=torch.tensor([2,0])
        p=logits.softmax(-1)[:,2]
        expected=torch.stack((-3*p[0].log(),-(1-p[1]).log()))
        torch.testing.assert_close(spam_binary_loss(logits,labels,2,3.),expected)
        spam_binary_loss(logits,labels,2,3.).mean().backward()
        self.assertTrue(torch.isfinite(logits.grad).all())
        self.assertTrue((logits.grad.abs().sum(0)>0).all())

    def test_extreme_logits_are_finite_and_nonspam_gradient_pushes_back(self):
        import torch
        from spam_objective import spam_binary_loss
        logits=torch.tensor([[1e4,-1e4],[-1e4,1e4]],requires_grad=True)
        loss=spam_binary_loss(logits,torch.tensor([1,0]),1,3.)
        self.assertTrue(torch.isfinite(loss).all());loss.sum().backward()
        self.assertLess(logits.grad[0,1],0);self.assertGreater(logits.grad[1,1],0)

    def test_equal_cost_gives_opposite_equal_boundary_gradients(self):
        import torch
        from spam_objective import spam_binary_loss
        logits=torch.zeros(2,2,requires_grad=True)
        loss=spam_binary_loss(logits,torch.tensor([1,0]),1,1.)
        torch.testing.assert_close(loss,torch.full((2,),__import__('math').log(2)))
        loss.sum().backward()
        torch.testing.assert_close(logits.grad[0],-logits.grad[1])


if __name__=='__main__':unittest.main()
