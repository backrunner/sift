import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from multilingual_views import (balanced_weights, digest, ExpectedPairs, load_spec,
    PairedRows, paired_loss)


LOCAL_DATA = Path(__file__).resolve().parents[3] / 'tools/apple-trainer/Training'


def arguments(**updates):
    values = dict(replay_alpha=.9, replay_temperature=2., label_smoothing=0.,
        replay_hard_label_mode='mixed', multilingual_mode='consistent',
        translation_consistency_weight=.1, replay_new_loss_weight=1.,
        replay_only_correct_teacher=True, replay_agreement_all_rows=True,
        action_loss_weight=0., spam_loss_weight=0.)
    return SimpleNamespace(**(values | updates))


class ViewDataTests(unittest.TestCase):
    def test_balancing_preserves_each_fine_label_mass(self):
        rows = ([dict(language='en', label='spam')] * 8
                + [dict(language='en', label='__sift_abstain__')] * 2
                + [dict(language='ja', label='spam')] * 2
                + [dict(language='ja', label='__sift_abstain__')] * 8)
        weights = balanced_weights(rows)
        for label in ('spam', '__sift_abstain__'):
            self.assertAlmostEqual(sum(w for r,w in zip(rows, weights) if r['label'] == label), 10.)
        self.assertLess(weights[0], weights[10])
        self.assertGreater(weights[8], weights[12])
        self.assertTrue(all(0 < w < 4 for w in weights))

    def test_extra_views_do_not_multiply_root_weight(self):
        rows = [dict(text='first'), dict(text='second')]
        data = PairedRows(rows, rows, {digest('first'): ['a','b','c']}, 'translated', 9)
        probe = ExpectedPairs(data, [2., 3.])
        self.assertEqual(len(probe), 4)
        self.assertAlmostEqual(sum(probe[i]['probe_weight'] for i in range(3)), 2.)
        self.assertEqual(probe[3]['probe_weight'], 3.)
        views = []
        for epoch in range(3):
            data.epoch = epoch
            views.append(data[0]['view_text'])
            self.assertEqual(data[0]['view_text'], data[0]['view_text'])
        self.assertEqual(set(views), {'a','b','c'})
        data.mode = 'uniform'
        self.assertEqual(data[0]['view_text'], 'first')
        self.assertEqual(len(ExpectedPairs(data, [2.,3.])), 2)

    @unittest.skipUnless((LOCAL_DATA / 'retired-signal-samples-v8.json').exists(), 'needs local research data')
    def test_spec_rejects_root_label_review_and_holdout_drift(self):
        from import_reviewed_public import keys
        rows = [dict(text='Are we still meeting for dinner tonight?', language='en', label='__sift_abstain__')]
        row = dict(text='我们今晚还一起吃晚饭吗？', language='zh', label='__sift_abstain__',
            source='translation-reviewed-v30:test', review='accepted', reviewReason='same social intent', tokenCount=9)
        spec = dict(schemaVersion=1, maxLength=96, rootTextSHA256=[digest(rows[0]['text'])],
            protectedSignatureSHA256=[], groups=[dict(groupID='dinner', label=row['label'],
                parents=[digest(rows[0]['text'])], translations=[row])])
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'spec.json'
            def check(value, pattern=None):
                path.write_text(json.dumps(value, ensure_ascii=False))
                if pattern:
                    with self.assertRaisesRegex(ValueError, pattern): load_spec(path, rows)
                else: self.assertEqual(len(load_spec(path, rows)[1]), 1)
            check(spec)
            value = copy.deepcopy(spec);value['rootTextSHA256'] = [];check(value, 'roots changed')
            value = copy.deepcopy(spec);value['groups'][0]['label'] = 'spam';check(value, 'cross-label')
            value = copy.deepcopy(spec);value['groups'][0]['translations'][0]['review'] = 'pending';check(value, 'unreviewed')
            value = copy.deepcopy(spec);value['protectedSignatureSHA256'] = [digest(k) for k in keys(row['text'],family=True)];check(value, 'protected')
            path.write_text(json.dumps(spec))
            with self.assertRaisesRegex(ValueError, 'token evidence'):
                load_spec(path, rows, lambda text: {'input_ids':list(range(97))})


@unittest.skipUnless(importlib.util.find_spec('torch') and importlib.util.find_spec('transformers'), 'requires trainer venv')
class PairedLossTests(unittest.TestCase):
    def setUp(self):
        import torch
        self.labels = torch.tensor([0, 1])
        self.mask = torch.zeros(2, dtype=torch.bool)
        self.pairs = torch.ones(2, dtype=torch.bool)
        self.logits = torch.tensor([[2., -1.], [1., 3.]], requires_grad=True)
        self.teacher = torch.tensor([[3., -1.], [-2., 3.]])

    def test_identical_views_reproduce_existing_correct_teacher_kd(self):
        import torch
        from replay_distillation import replay_distillation_loss
        expected = replay_distillation_loss(self.logits, self.teacher, self.labels, self.mask,
            .9, 2., only_correct_teacher=True, agreement_all_rows=True)
        actual = paired_loss(self.logits, self.logits, self.teacher, self.teacher,
            self.labels, self.mask, self.pairs, arguments())
        torch.testing.assert_close(actual, expected)
        actual.sum().backward()
        self.assertTrue(torch.isfinite(self.logits.grad).all())

    def test_wrong_original_teacher_disables_consistency_not_hard_label(self):
        import torch
        from replay_distillation import replay_distillation_loss
        wrong = -self.teacher
        view = self.logits.flip(-1)
        expected = .5 * (replay_distillation_loss(self.logits, wrong, self.labels, self.mask,
            .9, 2., only_correct_teacher=True, agreement_all_rows=True)
            + replay_distillation_loss(view, self.teacher, self.labels, self.mask,
            .9, 2., only_correct_teacher=True, agreement_all_rows=True))
        actual = paired_loss(self.logits, view, wrong, self.teacher,
            self.labels, self.mask, self.pairs, arguments())
        torch.testing.assert_close(actual, expected)

    def test_consistency_adds_only_bounded_js_on_distinct_eligible_pairs(self):
        import torch
        import math
        view = self.logits.flip(-1)
        pair_mask = torch.tensor([True, False])
        base = paired_loss(self.logits, view, self.teacher, self.teacher,
            self.labels, self.mask, pair_mask, arguments(multilingual_mode='translated'))
        actual = paired_loss(self.logits, view, self.teacher, self.teacher,
            self.labels, self.mask, pair_mask, arguments())
        delta = actual-base
        self.assertGreater(float(delta[0].detach()), 0.)
        self.assertLessEqual(float(delta[0].detach()), .1*math.log(2.))
        self.assertEqual(float(delta[1].detach()), 0.)
        actual.sum().backward()
        self.assertTrue(torch.isfinite(self.logits.grad).all())

    def test_full_probe_matches_dense_paired_gradient_including_view_weights(self):
        import torch
        from gradient_diagnostics import deterministic_terms, full_gradient_probe
        class Tiny(torch.nn.Module):
            def __init__(self):
                super().__init__();self.classifier = torch.nn.Linear(2,2)
            def forward(self, input_ids):
                return SimpleNamespace(logits=self.classifier(input_ids))
        torch.manual_seed(17)
        model=Tiny();teacher=Tiny().eval().requires_grad_(False)
        x=torch.tensor([[1.,0.],[1.,0.],[0.,1.]])
        v=torch.tensor([[2.,0.],[1.,1.],[0.,1.]])
        labels=torch.tensor([0,0,1]);weights=torch.tensor([.75,.75,2.])
        mask=torch.zeros(3,dtype=torch.bool);pairs=torch.tensor([True,True,False])
        loss=paired_loss(model(x).logits,model(v).logits,teacher(x).logits,teacher(v).logits,
            labels,mask,pairs,arguments())
        dense=(loss*weights).sum()/weights.sum();dense.backward()
        norm=sum(float(p.grad.square().sum()) for p in model.parameters())**.5
        batches=[dict(input_ids=x[a:b],view_input_ids=v[a:b],labels=labels[a:b],
            loss_weights=weights[a:b],correction_mask=mask[a:b],pair_mask=pairs[a:b]) for a,b in [(0,2),(2,3)]]
        result=full_gradient_probe(model,batches,lambda batch:deterministic_terms(model,batch,arguments(),teacher),'cpu')
        self.assertAlmostEqual(result['objective'],float(dense.detach()),places=6)
        self.assertAlmostEqual(result['unclippedFullGradientNorm'],norm,places=6)

    def test_real_modernbert_paired_training_updates_without_touching_teacher(self):
        import torch
        from transformers import ModernBertConfig, ModernBertForSequenceClassification
        from train_mmbert import train_model
        from unittest.mock import patch
        torch.manual_seed(22)
        config=ModernBertConfig(vocab_size=32,hidden_size=16,intermediate_size=24,
            num_hidden_layers=2,num_attention_heads=2,num_labels=2,pad_token_id=0,bos_token_id=1,eos_token_id=2)
        model=ModernBertForSequenceClassification(config);teacher=copy.deepcopy(model)
        before=copy.deepcopy(model.state_dict())
        rows=[dict(text='3',label='a',language='en'),dict(text='4',label='b',language='ja')]
        def tokenizer(texts,**kwargs):
            return {'input_ids':torch.tensor([[1,int(t),2,0] for t in texts]),
                    'attention_mask':torch.tensor([[1,1,1,0] for _ in texts])}
        args=arguments(num_epochs=1,seed=7,max_length=4,boundary_loss_weight=1.,train_label_rows=[],
            selected_label_loss_weight=1.,batch_size=2,learning_rate=.01,weight_decay=.01,
            warmup_ratio=0.,early_stopping_patience=0,replay_new_source_prefix=[],
            gradient_probe_every=1)
        summary={}
        with tempfile.TemporaryDirectory() as folder:
            args.multilingual_view_spec=Path(folder)/'spec.json';args.multilingual_view_spec.write_text('{}')
            spec={'groups':[{'translations':[{'text':'5','language':'zh'}]}]}
            with patch('multilingual_views.load_spec',return_value=(spec,{digest('3'):['5']})):
                train_model(model,tokenizer,rows,{'a':0,'b':1},args,'cpu',replay_teacher=teacher,optimization_summary=summary)
        self.assertEqual(summary['completedUpdates'],1)
        self.assertTrue(any(not torch.equal(v,model.state_dict()[k]) for k,v in before.items()))
        for key,value in before.items():torch.testing.assert_close(value,teacher.state_dict()[key],rtol=0,atol=0)


if __name__ == '__main__': unittest.main()
