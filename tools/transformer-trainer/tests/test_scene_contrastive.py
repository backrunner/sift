import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from scene_contrastive import SceneBatchSampler,scene_loss,load_groups,text_hash,forward_features


class SceneContrastiveTests(unittest.TestCase):
    def test_sampler_preserves_all_roots_and_complete_scenes(self):
        import torch
        groups=[list(range(9)),list(range(9,18)),list(range(18,27))]
        def draw():return list(SceneBatchSampler(70,32,groups,torch.Generator().manual_seed(321)))
        a=draw();self.assertEqual(a,draw());self.assertEqual(len(a),3)
        self.assertEqual(sorted(i for b in a for i in b),list(range(70)))
        for g in groups:self.assertEqual(sum(set(g)<=set(b) for b in a),1)
        self.assertLessEqual(max(map(len,a)),32)

    def test_loss_separates_classes_and_ignores_unrelated_rows(self):
        import torch
        good=torch.tensor([[1.,0.],[1.,.1],[-1.,0.],[-1.,.1],[.4,.7]],requires_grad=True)
        labels=torch.tensor([0,0,1,1,0]);groups=torch.tensor([0,0,0,0,-1])
        loss=scene_loss(good,labels,groups,.1)
        bad=good.detach()[[0,2,1,3,4]]
        self.assertLess(float(loss.mean()),float(scene_loss(bad,labels,groups,.1).mean()))
        self.assertEqual(float(loss[-1]),0.)
        loss.sum().backward();self.assertTrue(torch.isfinite(good.grad).all())
        torch.testing.assert_close(good.grad[-1],torch.zeros(2))
        altered=good.detach().clone();altered[-1]=torch.tensor([-999.,231.])
        torch.testing.assert_close(loss,scene_loss(altered,labels,groups,.1))

    def test_no_valid_pairs_returns_differentiable_zero(self):
        import torch
        x=torch.randn(3,4,requires_grad=True)
        loss=scene_loss(x,torch.tensor([0,1,2]),torch.tensor([-1,0,0]),.1)
        self.assertEqual(float(loss.sum()),0.);loss.sum().backward()
        torch.testing.assert_close(x.grad,torch.zeros_like(x))

    def test_manifest_rejects_changed_gold_and_duplicate_members(self):
        rows=[{'text':str(i),'label':str(i//2)} for i in range(4)]
        spec={'kind':'reviewed-scene-contrastive-groups','groups':[{'members':[{'textSHA256':text_hash(r['text']),'label':r['label']} for r in rows]}]}
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'spec.json';p.write_text(json.dumps(spec));self.assertEqual(load_groups(rows,p)[0],[[0,1,2,3]])
            rows[0]['label']='wrong'
            with self.assertRaises(ValueError):load_groups(rows,p)

    def test_capture_has_no_inference_state_or_persistent_hook(self):
        import torch
        from types import SimpleNamespace
        class Tiny(torch.nn.Module):
            def __init__(self):super().__init__();self.classifier=torch.nn.Linear(3,2)
            def forward(self,input_ids):return SimpleNamespace(logits=self.classifier(input_ids))
        model=Tiny();x=torch.randn(4,3);before=set(model.state_dict())
        out,features=forward_features(model,{'input_ids':x},True)
        torch.testing.assert_close(features,x);torch.testing.assert_close(out.logits,model(x).logits)
        self.assertEqual(set(model.state_dict()),before);self.assertFalse(model.classifier._forward_pre_hooks)

    def test_training_sam_matches_manual_scene_objective_with_uneven_tail(self):
        import copy
        import torch
        from types import SimpleNamespace
        from train_mmbert import train_model
        from sharpness_aware import sam_perturbation
        from training_optimization import parameter_groups
        class Tiny(torch.nn.Module):
            def __init__(self):
                super().__init__();self.encoder=torch.nn.Linear(1,4);self.classifier=torch.nn.Linear(4,2)
            def forward(self,input_ids):return SimpleNamespace(logits=self.classifier(self.encoder(input_ids).tanh()))
        torch.manual_seed(19);model=Tiny();manual=copy.deepcopy(model)
        rows=[dict(text=str(i+1),label='a' if i%2==0 else 'b',source='base') for i in range(7)]
        spec={'kind':'reviewed-scene-contrastive-groups','groups':[{'members':[
            {'textSHA256':text_hash(r['text']),'label':r['label']} for r in rows[:4]]}]}
        tokenizer=lambda texts,**kwargs:{'input_ids':torch.tensor([[float(t)] for t in texts])}
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'groups.json';path.write_text(json.dumps(spec))
            args=SimpleNamespace(num_epochs=1,seed=7,max_length=2,boundary_loss_weight=1.,train_label_rows=[],
                selected_label_loss_weight=1.,batch_size=4,learning_rate=.01,weight_decay=.01,label_smoothing=0.,
                warmup_ratio=0.,early_stopping_patience=0,sam_rho=.005,max_grad_norm=5.,gradient_accumulation_steps=2,
                scene_contrastive_spec=path,scene_contrastive_weight=.2,scene_contrastive_temperature=.1)
            train_model(model,tokenizer,rows,{'a':0,'b':1},args,'cpu')
        groups,_=parameter_groups(manual,.01,.01);optimizer=torch.optim.AdamW(groups,lr=.01)
        x=torch.arange(1,8).float().reshape(-1,1);y=torch.arange(7)%2;scene=torch.tensor([0,0,0,0,-1,-1,-1])
        def loss():
            output,features=forward_features(manual,{'input_ids':x},True)
            return (torch.nn.functional.cross_entropy(output.logits,y,reduction='none')+.2*scene_loss(features,y,scene,.1)).mean()
        loss().backward()
        with sam_perturbation(manual.parameters(),.005):
            optimizer.zero_grad(set_to_none=True);loss().backward()
        torch.nn.utils.clip_grad_norm_(manual.parameters(),5.);optimizer.step()
        for a,b in zip(model.parameters(),manual.parameters()):torch.testing.assert_close(a,b,rtol=1e-6,atol=1e-7)


if __name__=='__main__':unittest.main()
