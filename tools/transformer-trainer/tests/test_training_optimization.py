import copy
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from training_optimization import parameter_groups,update_plan


@unittest.skipUnless(importlib.util.find_spec('torch'),'requires torch')
class OptimizationTests(unittest.TestCase):
    def test_real_modernbert_last_four_layers_and_residual_head_use_llrd(self):
        import torch
        from transformers import ModernBertConfig, ModernBertForSequenceClassification
        from semantic_regularization import ActionResidualClassifier
        model=ModernBertForSequenceClassification(ModernBertConfig(vocab_size=32,
            hidden_size=16,intermediate_size=24,num_hidden_layers=12,
            num_attention_heads=2,num_labels=3,pad_token_id=0,bos_token_id=1,eos_token_id=2))
        model.model.embeddings.requires_grad_(False)
        for layer in model.model.layers[:8]:layer.requires_grad_(False)
        model.classifier=ActionResidualClassifier(model.classifier,[0,1,2])
        groups,_=parameter_groups(model,2e-5,.01,head_multiplier=2,layer_decay=.9)
        rates={id(p):g['lr'] for g in groups for p in g['params']}
        for i in range(8,12):
            for parameter in model.model.layers[i].parameters():
                self.assertAlmostEqual(rates[id(parameter)],2e-5*.9**(11-i))
        for parameter in model.classifier.parameters():self.assertEqual(rates[id(parameter)],4e-5)
        for parameter in model.head.parameters():self.assertEqual(rates[id(parameter)],4e-5)
        frozen=[*model.model.embeddings.parameters(),
                *[p for layer in model.model.layers[:8] for p in layer.parameters()]]
        self.assertTrue(all(id(parameter) not in rates for parameter in frozen))

    def test_groups_exclude_frozen_and_do_not_decay_norm_bias(self):
        import torch
        model=torch.nn.Module()
        model.model=torch.nn.Module()
        model.model.layers=torch.nn.ModuleList([torch.nn.Linear(2,2) for _ in range(3)])
        model.model.layers[0].requires_grad_(False)
        model.model.final_norm=torch.nn.LayerNorm(2)
        model.classifier=torch.nn.Linear(2,2)
        groups,_=parameter_groups(model,1e-5,.05,head_multiplier=2,layer_decay=.5)
        actual={id(p):g for g in groups for p in g['params']}
        self.assertEqual(len(actual),sum(p.requires_grad for p in model.parameters()))
        self.assertNotIn(id(model.model.layers[0].weight),actual)
        self.assertEqual(actual[id(model.classifier.weight)]['lr'],2e-5)
        self.assertEqual(actual[id(model.model.layers[1].weight)]['lr'],5e-6)
        self.assertEqual(actual[id(model.model.layers[2].weight)]['lr'],1e-5)
        self.assertEqual(actual[id(model.model.final_norm.weight)]['weight_decay'],0.)
        self.assertEqual(actual[id(model.classifier.bias)]['weight_decay'],0.)
        self.assertEqual(actual[id(model.classifier.weight)]['weight_decay'],.05)

    def test_accumulation_tail_matches_one_weighted_full_batch(self):
        import torch
        from train_mmbert import train_model
        class Tiny(torch.nn.Module):
            def __init__(self):
                super().__init__();self.linear=torch.nn.Linear(1,2)
            def forward(self,input_ids):return SimpleNamespace(logits=self.linear(input_ids))
        torch.manual_seed(12)
        one=Tiny();two=copy.deepcopy(one)
        rows=[dict(text=str(i+1),label='a' if i<2 else 'b',
            source='augmentation:boundary:reviewed' if i==0 else 'base') for i in range(3)]
        tokenizer=lambda texts,**kwargs:{'input_ids':torch.tensor([[float(t)] for t in texts])}
        base=dict(num_epochs=1,seed=7,max_length=2,boundary_loss_weight=2.,train_label_rows=[],
            selected_label_loss_weight=1.,batch_size=3,learning_rate=.01,weight_decay=.01,
            label_smoothing=0.,warmup_ratio=0.,early_stopping_patience=0)
        first,second={},{}
        train_model(one,tokenizer,rows,{'a':0,'b':1},SimpleNamespace(**base),'cpu',optimization_summary=first)
        base.update(batch_size=2,gradient_accumulation_steps=2)
        train_model(two,tokenizer,rows,{'a':0,'b':1},SimpleNamespace(**base),'cpu',optimization_summary=second)
        for a,b in zip(one.parameters(),two.parameters()):torch.testing.assert_close(a,b,atol=1e-7,rtol=1e-6)
        self.assertEqual(first['completedUpdates'],1)
        self.assertEqual(second['plannedUpdates'],1)
        self.assertAlmostEqual(first['meanGradientNorm'],second['meanGradientNorm'],places=6)
        self.assertAlmostEqual(first['learningRateTrace'][0]['loss'],second['learningRateTrace'][0]['loss'],places=6)

    def test_linear_schedule_uses_update_count_and_preserves_lr_ratios(self):
        import torch
        from transformers import get_scheduler
        plan=update_plan(5,2,2,.2)
        self.assertEqual(plan,{'plannedUpdates':6,'warmupUpdates':1,'updatesPerEpoch':3})
        p=torch.nn.Parameter(torch.ones(1));q=torch.nn.Parameter(torch.ones(1))
        optimizer=torch.optim.AdamW([{'params':[p],'lr':1e-5},{'params':[q],'lr':2e-5}])
        scheduler=get_scheduler('linear',optimizer=optimizer,num_warmup_steps=1,num_training_steps=6)
        rates=[]
        for _ in range(6):
            optimizer.step();scheduler.step();rates.append([g['lr'] for g in optimizer.param_groups])
        self.assertAlmostEqual(rates[0][0],1e-5)
        self.assertEqual(rates[-1],[0.,0.])
        for a,b in rates:self.assertAlmostEqual(b,2*a)
