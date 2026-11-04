import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))


@unittest.skipUnless(importlib.util.find_spec('torch'),'requires trainer venv')
class AnchorTests(unittest.TestCase):
    def test_anchor_gradient_and_uneven_probe_match_dense_objective(self):
        import torch
        from parameter_anchor import ParameterAnchor
        from gradient_diagnostics import full_gradient_probe
        model=torch.nn.Linear(1,1,bias=False)
        with torch.no_grad():model.weight.fill_(2.)
        anchor=ParameterAnchor(model,.3);identity=anchor.sha256()
        with torch.no_grad():model.weight.fill_(3.)
        x=torch.tensor([[1.],[2.],[4.]])
        objective=model(x).square().mean()+anchor.penalty()
        objective.backward();expected=float(model.weight.grad.norm())
        def terms(batch):return model(batch['x']).square().sum(),torch.tensor(float(len(batch['x']))),len(batch['x'])
        probe=full_gradient_probe(model,[{'x':x[:2]},{'x':x[2:]}],terms,'cpu',anchor.penalty)
        self.assertAlmostEqual(probe['unclippedFullGradientNorm'],expected,places=5)
        self.assertAlmostEqual(probe['parameterAnchorPenalty'],.15,places=6)
        self.assertEqual(anchor.sha256(),identity)
        self.assertNotEqual(ParameterAnchor(model,.3).sha256(),identity)

    def test_agreement_kd_never_overrides_reviewed_disagreement(self):
        import torch
        from replay_distillation import replay_distillation_loss
        student=torch.tensor([[1.,0.],[1.,0.]],requires_grad=True)
        teacher=torch.tensor([[5.,0.],[5.,0.]])
        labels=torch.tensor([0,1]);mask=torch.tensor([True,True])
        loss=replay_distillation_loss(student,teacher,labels,mask,.9,2.,only_correct_teacher=True,agreement_all_rows=True)
        hard=torch.nn.functional.cross_entropy(student,labels,reduction='none')
        torch.testing.assert_close(loss[1],hard[1])
        self.assertNotAlmostEqual(float(loss[0]),float(hard[0]))
        with self.assertRaises(ValueError):replay_distillation_loss(student,teacher,labels,mask,.9,2.,agreement_all_rows=True)

    def test_failed_gate_restores_best_diagnostic_weights_and_archives_terminal(self):
        import torch
        import train_mmbert
        class Tiny(torch.nn.Module):
            def __init__(self):super().__init__();self.classifier=torch.nn.Linear(2,2)
            def forward(self,input_ids,**kw):return SimpleNamespace(logits=self.classifier(input_ids.float()))
        def tokenizer(texts,**kw):return {'input_ids':torch.tensor([[int(t),1] for t in texts])}
        rows=[{'text':str(i),'label':'a' if i%2 else 'b','source':'reviewed'} for i in range(1,6)]
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);data=root/'data.ndjson';data.write_text(''.join(json.dumps(r)+'\n' for r in rows))
            args=SimpleNamespace(num_epochs=2,seed=17,max_length=2,batch_size=2,
                learning_rate=.1,weight_decay=.01,label_smoothing=0.,warmup_ratio=0.,
                boundary_loss_weight=1.,train_label_rows=[],selected_label_loss_weight=1.,
                early_stopping_patience=3,early_stopping_delta=0.,diagnostic_best_fallback=True,
                save_epoch_parameters=True,out=root,training_state=root/'state.pt',resume_training_state=None,
                input=data,validation_input=data,replay_teacher=None,validation_max_nonspam_junk=0)
            predictions=[{'negativeLogLikelihood':1.}]*3
            mocked=[(2/3,{},[('a','a'),('a','b'),('b','b')],predictions),
                    (1/3,{},[('a','b'),('a','b'),('b','b')],predictions)]
            model=Tiny();history=[];summary={}
            with patch.object(train_mmbert,'evaluate_model',side_effect=mocked):
                train_mmbert.train_model(model,tokenizer,rows,{'a':0,'b':1},args,'cpu',
                    validation_rows=rows,selection_history=history,validation_actions={'a':'allow','b':'junk'},optimization_summary=summary)
            self.assertEqual(summary['selectedCheckpointEpoch'],1)
            self.assertFalse(summary['selectedCheckpointEligible'])
            self.assertFalse(any(p['selected'] for p in history))
            first=torch.load(root/'epochs/epoch-001.pt',weights_only=True)['parameters']
            last=torch.load(root/'epochs/epoch-002.pt',weights_only=True)['parameters']
            for name,p in model.named_parameters():torch.testing.assert_close(p,first[name],rtol=0,atol=0)
            self.assertTrue(any(not torch.equal(first[n],last[n]) for n in first))
