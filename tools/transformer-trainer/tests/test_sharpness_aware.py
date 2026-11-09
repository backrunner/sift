import copy
import importlib.util
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sharpness_aware import sam_perturbation, validate_sam_model, prune_epoch_archives


@unittest.skipUnless(importlib.util.find_spec('torch') and importlib.util.find_spec('transformers'), 'requires trainer venv')
class SharpnessTests(unittest.TestCase):
    def test_restore_is_exact_after_second_pass_failure_and_zero_gradient(self):
        import torch
        p = torch.nn.Parameter(torch.tensor([1.001, -3.1415]));original = p.detach().clone()
        p.grad = torch.tensor([2., -7.])
        with self.assertRaisesRegex(RuntimeError, 'second pass'):
            with sam_perturbation([p], .05):
                self.assertFalse(torch.equal(p, original))
                raise RuntimeError('second pass failed')
        self.assertTrue(torch.equal(p, original))
        p.grad = torch.zeros_like(p)
        with sam_perturbation([p], .05):
            self.assertTrue(torch.equal(p, original))

    def test_unsafe_gradient_and_stochastic_model_rejected(self):
        import torch
        p = torch.nn.Parameter(torch.ones(2));p.grad = torch.tensor([float('nan'), 1.])
        with self.assertRaisesRegex(ValueError, 'Non-finite'):
            with sam_perturbation([p], .05):
                self.fail('must not perturb')
        self.assertTrue(torch.equal(p, torch.ones(2)))
        with self.assertRaisesRegex(ValueError, 'dropout-free'):
            validate_sam_model(torch.nn.Dropout(.1), .05)
        validate_sam_model(torch.nn.Dropout(.1), 0.)

    def test_trainer_accumulation_matches_manual_sam_with_weighted_uneven_tail(self):
        import torch
        from train_mmbert import train_model
        class Tiny(torch.nn.Module):
            def __init__(self):
                super().__init__();self.linear=torch.nn.Linear(1,2)
            def forward(self,input_ids):
                return SimpleNamespace(logits=self.linear(input_ids))
        torch.manual_seed(12)
        full=Tiny();split=copy.deepcopy(full);manual=copy.deepcopy(full)
        rows=[dict(text=str(i+1),label='a' if i<2 else 'b',
            source='augmentation:boundary:reviewed' if i==0 else 'base') for i in range(3)]
        tokenizer=lambda texts,**kwargs:{'input_ids':torch.tensor([[float(t)] for t in texts])}
        arguments=dict(num_epochs=1,seed=7,max_length=2,boundary_loss_weight=2.,train_label_rows=[],
            selected_label_loss_weight=1.,batch_size=3,learning_rate=.01,weight_decay=.01,
            label_smoothing=0.,warmup_ratio=0.,early_stopping_patience=0,sam_rho=.05,
            max_grad_norm=5.)
        a,b={},{}
        train_model(full,tokenizer,rows,{'a':0,'b':1},SimpleNamespace(**arguments),'cpu',optimization_summary=a)
        arguments.update(batch_size=2,gradient_accumulation_steps=2)
        train_model(split,tokenizer,rows,{'a':0,'b':1},SimpleNamespace(**arguments),'cpu',optimization_summary=b)
        from training_optimization import parameter_groups
        groups,_=parameter_groups(manual,.01,.01)
        optimizer=torch.optim.AdamW(groups,lr=.01)
        weights=torch.tensor([2.,1.,1.]);labels=torch.tensor([0,0,1]);x=torch.tensor([[1.],[2.],[3.]])
        def loss():
            return (torch.nn.functional.cross_entropy(manual(x).logits,labels,reduction='none')*weights).sum()/4
        loss().backward()
        original=[p.detach().clone() for p in manual.parameters()]
        vector=torch.cat([p.grad.reshape(-1) for p in manual.parameters()])
        with torch.no_grad():
            for p in manual.parameters():p.add_(.05*p.grad/vector.norm())
        optimizer.zero_grad(set_to_none=True);loss().backward()
        with torch.no_grad():
            for p,old in zip(manual.parameters(),original):p.copy_(old)
        norm=torch.nn.utils.clip_grad_norm_(manual.parameters(),5.);optimizer.step()
        for expected,one,two in zip(manual.parameters(),full.parameters(),split.parameters()):
            torch.testing.assert_close(one,expected,rtol=1e-6,atol=1e-7)
            torch.testing.assert_close(two,expected,rtol=1e-6,atol=1e-7)
        self.assertAlmostEqual(a['meanGradientNorm'],float(norm),places=6)
        self.assertAlmostEqual(a['meanGradientNorm'],b['meanGradientNorm'],places=6)
        self.assertEqual(a['completedUpdates'],1);self.assertEqual(b['completedUpdates'],1)

    def test_mixed_batch_two_pass_modernbert_cpu_mps_parity(self):
        import torch
        from transformers import ModernBertConfig, ModernBertForSequenceClassification
        from training_backend import enable_frozen_boundary_input_gradient
        if not torch.backends.mps.is_available():self.skipTest('requires MPS')
        torch.manual_seed(321)
        reference=ModernBertForSequenceClassification(ModernBertConfig(vocab_size=32,
            hidden_size=16,intermediate_size=24,num_hidden_layers=3,num_attention_heads=2,
            num_labels=2,pad_token_id=0,bos_token_id=1,eos_token_id=2)).eval()
        reference.model.embeddings.requires_grad_(False);reference.model.layers[0].requires_grad_(False)
        model=copy.deepcopy(reference).to('mps');enable_frozen_boundary_input_gradient(model,'mps')
        for count in (9,7,3,9):
            batches={}
            for value,device in ((reference,'cpu'),(model,'mps')):
                x=torch.tensor([[1,4,5,2]]*count,device=device)
                y=torch.arange(count,device=device)%2
                value.zero_grad(set_to_none=True)
                torch.nn.functional.cross_entropy(value(x).logits,y).backward()
                originals={n:p.detach().clone() for n,p in value.named_parameters()}
                with sam_perturbation(value.parameters(),.05):
                    value.zero_grad(set_to_none=True)
                    torch.nn.functional.cross_entropy(value(x).logits,y).backward()
                self.assertTrue(all(torch.equal(p,originals[n]) for n,p in value.named_parameters()))
                batches[device]={n:p.grad.detach().cpu().clone() for n,p in value.named_parameters() if p.requires_grad}
            for name,grad in batches['cpu'].items():
                torch.testing.assert_close(batches['mps'][name],grad,rtol=2e-3,atol=2e-5)

    def test_compact_retention_preserves_selected_latest_and_other_files(self):
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp)
            for name in ('epoch-001.pt','epoch-002.pt','epoch-003.pt','epoch-notes.pt','other.pt'):
                (p/name).write_text('fixture')
            self.assertEqual(prune_epoch_archives(p,3,1),['epoch-002.pt'])
            self.assertEqual({x.name for x in p.iterdir()}, {'epoch-001.pt','epoch-003.pt','epoch-notes.pt','other.pt'})


if __name__=='__main__':unittest.main()
