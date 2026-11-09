import copy
import importlib.util
from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from training_backend import enable_frozen_boundary_input_gradient


@unittest.skipUnless(importlib.util.find_spec('torch') and importlib.util.find_spec('transformers'), 'requires trainer venv')
class FrozenBoundaryTests(unittest.TestCase):
    def make_model(self):
        from transformers import ModernBertConfig, ModernBertForSequenceClassification
        model=ModernBertForSequenceClassification(ModernBertConfig(vocab_size=32,
            hidden_size=16,intermediate_size=24,num_hidden_layers=3,num_attention_heads=2,
            num_labels=2,pad_token_id=0,bos_token_id=1,eos_token_id=2))
        model.model.embeddings.requires_grad_(False)
        model.model.layers[0].requires_grad_(False)
        return model

    def test_guard_keeps_trainable_set_and_gradients_and_is_idempotent(self):
        import torch
        torch.manual_seed(57)
        model=self.make_model().eval();reference=copy.deepcopy(model)
        trainable=[n for n,p in model.named_parameters() if p.requires_grad]
        report=enable_frozen_boundary_input_gradient(model,'mps')
        self.assertTrue(report['enabled']);self.assertEqual(report['firstTrainableLayer'],1)
        enable_frozen_boundary_input_gradient(model,'mps')
        self.assertEqual(len(model.model.layers[1].attn_norm._forward_pre_hooks),1)
        self.assertEqual(trainable,[n for n,p in model.named_parameters() if p.requires_grad])
        for count in (3,1,2,3):
            x=torch.tensor([[1,4,5,2]]*count)
            for value in (model,reference):
                value.zero_grad(set_to_none=True);value(x).logits.square().sum().backward()
            for (name,a),b in zip(model.named_parameters(),reference.parameters()):
                if a.requires_grad:torch.testing.assert_close(a.grad,b.grad,rtol=1e-5,atol=1e-6)
                else:self.assertIsNone(a.grad,name)
        with torch.inference_mode():
            torch.testing.assert_close(model(x).logits,reference(x).logits)

    def test_full_encoder_and_cpu_are_unchanged(self):
        model=self.make_model()
        self.assertFalse(enable_frozen_boundary_input_gradient(model,'cpu')['enabled'])
        model.model.layers[0].requires_grad_(True)
        self.assertFalse(enable_frozen_boundary_input_gradient(model,'mps')['enabled'])

    def test_mps_mixed_batch_backward_matches_cpu_with_guard(self):
        import torch
        if not torch.backends.mps.is_available():self.skipTest('MPS not available')
        torch.manual_seed(17)
        reference=self.make_model().eval();model=copy.deepcopy(reference).to('mps')
        enable_frozen_boundary_input_gradient(model,'mps')
        for count in (9,7,3,9):
            x=torch.tensor([[1,4,5,2]]*count)
            for value,device in ((reference,'cpu'),(model,'mps')):
                value.zero_grad(set_to_none=True);value(x.to(device)).logits.square().mean().backward()
            for a,b in zip(model.parameters(),reference.parameters()):
                if a.requires_grad:torch.testing.assert_close(a.grad.cpu(),b.grad,rtol=2e-3,atol=2e-5)


if __name__=='__main__':unittest.main()
