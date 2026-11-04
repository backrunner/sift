import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))


@unittest.skipUnless(importlib.util.find_spec('torch'),'requires torch')
class SemanticRegularizationTests(unittest.TestCase):
    def test_zero_initialized_hierarchy_preserves_original(self):
        import torch
        from semantic_regularization import ActionResidualClassifier
        torch.manual_seed(9)
        leaf=torch.nn.Linear(8,5)
        head=ActionResidualClassifier(leaf,[0,1,1,2,3])
        features=torch.randn(11,8)
        torch.testing.assert_close(head(features),leaf(features),rtol=0,atol=0)

    def test_fold_preserves_trained_logits_and_parameter_count(self):
        import torch
        from semantic_regularization import ActionResidualClassifier
        for bias in (True,False):
            head=ActionResidualClassifier(torch.nn.Linear(8,5,bias=bias),[0,1,1,2,3])
            with torch.no_grad():
                head.action.weight.normal_(); head.action.bias.normal_()
            features=torch.randn(21,8)
            fused=head.fold()
            torch.testing.assert_close(head(features),fused(features),atol=2e-6,rtol=2e-6)
            self.assertEqual(sum(p.numel() for p in fused.parameters()),45)

    def test_taxonomy_overrides_and_abstention_action_targets(self):
        import torch
        import json
        from model_contract import model_actions
        from semantic_regularization import ActionResidualClassifier,action_cross_entropy
        taxonomy=json.loads((Path(__file__).resolve().parents[3]/'packages/taxonomy/taxonomy.json').read_text())
        actions=model_actions(taxonomy)
        labels=['carrier.promotion','carrier.billing','spam','__sift_abstain__']
        ordered=sorted(set(actions.values()))
        ids=[ordered.index(actions[label]) for label in labels]
        self.assertEqual(len(set(ids)),4)
        head=ActionResidualClassifier(torch.nn.Linear(6,4),ids)
        head(torch.randn(4,6))
        loss=action_cross_entropy(head,torch.arange(4)).mean()
        loss.backward()
        self.assertTrue(torch.isfinite(loss))
        self.assertGreater(head.action.weight.grad.abs().sum(),0)

    def test_rdrop_is_symmetric_zero_for_equal_and_has_both_gradients(self):
        import torch
        from semantic_regularization import symmetric_kl
        a=torch.tensor([[1.,3.,-4.],[2.,0.,1.]],requires_grad=True)
        b=torch.tensor([[4.,1.,-2.],[0.,2.,1.]],requires_grad=True)
        torch.testing.assert_close(symmetric_kl(a,a),torch.zeros(2))
        torch.testing.assert_close(symmetric_kl(a,b),symmetric_kl(b,a))
        self.assertTrue((symmetric_kl(a,b)>0).all())
        symmetric_kl(a,b).sum().backward()
        self.assertGreater(a.grad.abs().sum(),0)
        self.assertGreater(b.grad.abs().sum(),0)

    def test_rdrop_matches_bidirectional_kl_reference_and_extreme_logits(self):
        import torch
        from torch.nn import functional as F
        from semantic_regularization import symmetric_kl
        a=torch.tensor([[1e4,0.,-1e4],[2.,1.,4.]])
        b=torch.tensor([[-1e4,0.,1e4],[0.,5.,1.]])
        la,lb=F.log_softmax(a,-1),F.log_softmax(b,-1)
        expected=.5*(F.kl_div(la,lb.exp(),reduction='none').sum(-1)+F.kl_div(lb,la.exp(),reduction='none').sum(-1))
        torch.testing.assert_close(symmetric_kl(a,b),expected)
        self.assertTrue(torch.isfinite(expected).all())

    @unittest.skipUnless(importlib.util.find_spec('transformers'),'requires transformers')
    def test_real_modernbert_training_fold_and_standard_checkpoint_reload(self):
        import torch
        from transformers import ModernBertConfig,ModernBertForSequenceClassification
        from semantic_regularization import ActionResidualClassifier,action_cross_entropy,symmetric_kl
        torch.manual_seed(17)
        config=ModernBertConfig(vocab_size=32,hidden_size=16,intermediate_size=32,
            num_hidden_layers=1,num_attention_heads=2,num_labels=4,cls_token_id=1,pad_token_id=0,
            classifier_dropout=.1,attn_implementation='eager')
        model=ModernBertForSequenceClassification(config)
        model.classifier=ActionResidualClassifier(model.classifier,[0,1,1,2])
        batch={'input_ids':torch.randint(1,32,(3,8)),'attention_mask':torch.ones(3,8,dtype=torch.long)}
        labels=torch.tensor([0,1,3])
        optimizer=torch.optim.AdamW(model.parameters(),lr=.001)
        first=model(**batch).logits
        action_first=action_cross_entropy(model.classifier,labels)
        second=model(**batch).logits
        loss=(.5*(torch.nn.functional.cross_entropy(first,labels)+torch.nn.functional.cross_entropy(second,labels))
            +symmetric_kl(first,second).mean()+.15*(action_first+action_cross_entropy(model.classifier,labels)).mean())
        loss.backward(); optimizer.step(); model.eval()
        with torch.no_grad():
            before=model(**batch).logits
            model.classifier=model.classifier.fold()
            torch.testing.assert_close(before,model(**batch).logits,atol=1e-6,rtol=1e-5)
            with tempfile.TemporaryDirectory() as directory:
                model.save_pretrained(directory)
                loaded=ModernBertForSequenceClassification.from_pretrained(directory,attn_implementation='eager').eval()
                self.assertIsInstance(loaded.classifier,torch.nn.Linear)
                torch.testing.assert_close(before,loaded(**batch).logits,atol=1e-6,rtol=1e-5)


if __name__=='__main__':
    unittest.main()
