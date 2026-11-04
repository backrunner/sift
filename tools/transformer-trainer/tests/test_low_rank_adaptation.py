import copy
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))


@unittest.skipUnless(importlib.util.find_spec('torch'),'requires trainer venv')
class LowRankTests(unittest.TestCase):
    def test_zero_initialized_branch_preserves_model_and_learns(self):
        import torch
        from low_rank_adaptation import LoRALinear
        base=torch.nn.Linear(4,6);original=copy.deepcopy(base);layer=LoRALinear(base,2,4.,.5)
        x=torch.randn(3,4)
        torch.testing.assert_close(layer(x),original(x),rtol=0,atol=0)
        layer(x).square().sum().backward()
        self.assertGreater(float(layer.lora_B.grad.norm()),0.)
        self.assertEqual(float(layer.lora_A.grad.norm()),0.)
        self.assertIsNone(base.weight.grad)

    def test_merge_preserves_outputs_keys_and_is_idempotent(self):
        import torch
        from low_rank_adaptation import LoRALinear
        layer=LoRALinear(torch.nn.Linear(5,7),2,4.,.1).eval()
        with torch.no_grad():layer.lora_B.normal_(0,.1)
        x=torch.randn(2,3,5);before=layer(x).detach();merged=layer.merged()
        torch.testing.assert_close(merged(x),before,rtol=1e-5,atol=1e-6)
        weight=merged.weight.detach().clone();layer.merged()
        torch.testing.assert_close(merged.weight,weight,rtol=0,atol=0)
        torch.testing.assert_close(layer(x),before,rtol=1e-5,atol=1e-6)
        self.assertEqual(set(merged.state_dict()),{'weight','bias'})

    def test_only_adapters_and_head_train_and_merge_restores_original_abi(self):
        import torch
        from low_rank_adaptation import install_attention_lora,merge_attention_lora
        class Attention(torch.nn.Module):
            def __init__(self):
                super().__init__();self.Wqkv=torch.nn.Linear(4,12);self.Wo=torch.nn.Linear(4,4)
            def forward(self,x):return self.Wo(torch.tanh(self.Wqkv(x)[...,:4]))
        class Layer(torch.nn.Module):
            def __init__(self):
                super().__init__();self.attn=Attention();self.mlp=torch.nn.Linear(4,4)
            def forward(self,x):return self.mlp(self.attn(x))
        class Tiny(torch.nn.Module):
            def __init__(self):
                super().__init__();self.model=torch.nn.Module();self.model.layers=torch.nn.ModuleList([Layer(),Layer()]);self.model.final_norm=torch.nn.LayerNorm(4);self.head=torch.nn.Linear(4,4);self.classifier=torch.nn.Linear(4,3)
            def forward(self,x):
                for layer in self.model.layers:x=layer(x)
                return self.classifier(self.head(self.model.final_norm(x)))
        model=Tiny();original=copy.deepcopy(model.state_dict());report=install_attention_lora(model,1,2,4.,0.)
        self.assertEqual(len(report['modules']),2)
        self.assertTrue(all('.lora_' in n or n.startswith(('head.','classifier.')) for n,p in model.named_parameters() if p.requires_grad))
        optimizer=torch.optim.AdamW([p for p in model.parameters() if p.requires_grad],lr=.01)
        x=torch.randn(3,4);model(x).square().sum().backward();optimizer.step()
        for name,p in model.named_parameters():
            if name.startswith('model.') and '.lora_' not in name:
                torch.testing.assert_close(p,original[name.replace('.base.','.')],rtol=0,atol=0)
        twin=Tiny();install_attention_lora(twin,1,2,4.,0.);twin.load_state_dict(model.state_dict())
        model.eval();twin.eval();torch.testing.assert_close(model(x),twin(x))
        before=model(x).detach();merged=merge_attention_lora(model)
        self.assertEqual(merged['runtimeAdditionalParameters'],0)
        self.assertEqual(set(model.state_dict()),set(original))
        torch.testing.assert_close(model(x),before,rtol=1e-5,atol=1e-6)

    def test_invalid_projection_or_rank_is_rejected(self):
        import torch
        from low_rank_adaptation import LoRALinear
        for base,rank,alpha,dropout in [(torch.nn.ReLU(),2,4.,0.),(torch.nn.Linear(2,3),4,4.,0.),
            (torch.nn.Linear(2,3),1,float('nan'),0.),(torch.nn.Linear(2,3),1,4.,1.)]:
            with self.assertRaises(ValueError):LoRALinear(base,rank,alpha,dropout)

    def test_all_nonspam_gate_counts_legitimate_promotions(self):
        import torch
        import train_mmbert
        class Tiny(torch.nn.Module):
            def __init__(self):super().__init__();self.classifier=torch.nn.Linear(2,2)
            def forward(self,input_ids):return SimpleNamespace(logits=self.classifier(input_ids.float()))
        def tokenizer(texts,**kwargs):return {'input_ids':torch.ones(len(texts),2)}
        rows=[{'text':'a','label':'promotion','source':'reviewed'},{'text':'b','label':'spam','source':'reviewed'}]
        args=SimpleNamespace(num_epochs=1,seed=17,max_length=2,batch_size=2,learning_rate=.01,
            weight_decay=.01,label_smoothing=.02,warmup_ratio=0.,boundary_loss_weight=1.,
            train_label_rows=[],selected_label_loss_weight=1.,early_stopping_patience=1,
            early_stopping_delta=0.,validation_max_benign_junk=0,validation_max_nonspam_junk=0,
            validation_min_spam_recall=1.)
        pairs=[('promotion','spam'),('spam','spam')]
        result=(.5,{},pairs,[{'negativeLogLikelihood':1.},{'negativeLogLikelihood':1.}])
        history=[]
        with patch.object(train_mmbert,'evaluate_model',return_value=result):
            train_mmbert.train_model(Tiny(),tokenizer,rows,{'promotion':0,'spam':1},args,'cpu',
                validation_rows=rows,selection_history=history,
                validation_actions={'promotion':'promotion','spam':'junk'})
        self.assertEqual(history[0]['actionMetrics']['benignToJunk'],0)
        self.assertEqual(history[0]['actionMetrics']['nonSpamToJunk'],1)
        self.assertFalse(history[0]['actionGatesPassed'])

    @unittest.skipUnless(importlib.util.find_spec('transformers'),'requires transformers')
    def test_modernbert_forward_training_and_merged_checkpoint_reload(self):
        import torch
        import tempfile
        from transformers import ModernBertConfig,ModernBertForSequenceClassification,AutoModelForSequenceClassification
        from low_rank_adaptation import install_attention_lora,merge_attention_lora
        config=ModernBertConfig(vocab_size=64,hidden_size=16,intermediate_size=32,
            num_hidden_layers=2,num_attention_heads=4,num_labels=3,max_position_embeddings=128,
            global_attn_every_n_layers=2,local_attention=8,pad_token_id=0,bos_token_id=1,
            eos_token_id=2,reference_compile=False)
        config._attn_implementation='eager'
        model=ModernBertForSequenceClassification(config).eval()
        inputs={'input_ids':torch.randint(3,64,(2,8)),'attention_mask':torch.ones(2,8,dtype=torch.long)}
        before=model(**inputs).logits.detach();original_keys=set(model.state_dict())
        install_attention_lora(model,1,2,4.,.05);model.eval()
        torch.testing.assert_close(model(**inputs).logits,before,rtol=0,atol=0)
        optimizer=torch.optim.AdamW([p for p in model.parameters() if p.requires_grad],lr=.001)
        model.train();model(**inputs,labels=torch.tensor([0,2])).loss.backward()
        self.assertTrue(any(float(p.grad.norm())>0 for n,p in model.named_parameters() if 'lora_B' in n))
        optimizer.step();model.eval();expected=model(**inputs).logits.detach()
        merge_attention_lora(model)
        self.assertEqual(set(model.state_dict()),original_keys)
        torch.testing.assert_close(model(**inputs).logits,expected,rtol=1e-5,atol=1e-6)
        with tempfile.TemporaryDirectory() as folder:
            model.save_pretrained(folder)
            reloaded=AutoModelForSequenceClassification.from_pretrained(folder,local_files_only=True).eval()
            torch.testing.assert_close(reloaded(**inputs).logits,expected,rtol=1e-5,atol=1e-6)
