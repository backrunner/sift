import copy
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from language_control_v52 import build_spec, validate, install, install_language_probes, select, eligible

LABELS = {'normal': 0, 'spam': 1, 'promotion': 2, 'carrier.promotion': 3}


LOCAL_DATA = Path(__file__).resolve().parents[3] / 'tools/apple-trainer/Training'


def rows():
    result = []
    for lang, distribution in [('ja', {'normal':4,'promotion':1,'spam':1}),
                               ('vi', {'normal':4,'promotion':4,'spam':4}),
                               ('en', {'normal':1})]:
        for label, n in distribution.items():
            for _ in range(n):
                result.append({'text':str(len(result)+1),'label':label,'language':lang,'source':'reviewed'})
    return result


class WeightAndQualityTests(unittest.TestCase):
    def test_downweight_only_matches_reference_without_removing_fraud(self):
        data = rows(); spec = build_spec(data, 'sha'); validate(data, spec)
        self.assertEqual(spec['vietnameseWeights'], {'normal':1.,'commercial':.25,'harmful':.25})
        self.assertEqual(spec['vietnameseWeightMass'], 6.)
        self.assertEqual(spec['japaneseIntentFractions'], spec['vietnameseWeightedIntentFractions'])
        self.assertEqual(len(spec['entries']), len(data))
        self.assertTrue(all(e['weight'] == 1 for e in spec['entries'].values() if e['language'] != 'vi'))
        changed = copy.deepcopy(spec); next(iter(changed['entries'].values()))['weight'] = .7
        with self.assertRaisesRegex(ValueError, 'differs'): validate(data, changed)
        changed = copy.deepcopy(data); changed[0]['language'] = 'vi'
        with self.assertRaises(ValueError): validate(changed, spec)
        with self.assertRaisesRegex(ValueError, 'all three intents'):
            build_spec([r for r in data if not (r['language']=='vi' and r['label']=='spam')], 'sha')

    def test_training_only_lookup_does_not_weight_or_reject_unseen_evaluation(self):
        import torch
        import train_mmbert as train
        class Model(torch.nn.Module):
            def forward(self, input_ids):
                return SimpleNamespace(logits=torch.tensor([[0., 2., -1., -2.]]).repeat(len(input_ids), 1))
        tokenize = lambda texts, **kw: {'input_ids':torch.ones((len(texts),1))}
        data = rows(); spec = build_spec(data, 'sha')
        evaluation = [{'text':'unseen normal SMS','label':'normal'}]
        expected = train.evaluate_model(Model(), tokenize, evaluation, LABELS, list(LABELS), 2, 'cpu')
        original_collate, original_evaluate = train.make_collate, train.evaluate_model
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)/'weights.json'; p.write_text(json.dumps(spec))
            for enabled in (False, True):
                restore = install(p, enabled)
                try:
                    actual = train.evaluate_model(Model(), tokenize, evaluation, LABELS, list(LABELS), 2, 'cpu')
                    self.assertEqual(actual, expected)
                    with self.assertRaises(KeyError) if enabled else self.subTest():
                        train.make_collate(tokenize,2)([{'text':'not admitted','label':0}])
                finally: restore()
                self.assertIs(train.make_collate, original_collate)
                self.assertIs(train.evaluate_model, original_evaluate)

    @unittest.skipUnless((LOCAL_DATA / 'signal-language-quality-v50.json').exists(), 'needs local research data')
    def test_quality_revision_preserves_all_non_vietnamese_and_all_harmful(self):
        from approved_signal import ROOT, verify
        from prepare_enrichment_v16 import read
        a = verify(ROOT/'tools/apple-trainer/Training/signal-language-quality-v50.json')
        b = verify(ROOT/'tools/apple-trainer/Training/signal-language-quality-v52.json')
        old, new = read(ROOT/a['training']), read(ROOT/b['training'])
        self.assertEqual([r for r in old if r['language']!='vi'], [r for r in new if r['language']!='vi'])
        self.assertEqual([r for r in old if r['language']=='vi' and r['label']=='spam'],
                         [r for r in new if r['language']=='vi' and r['label']=='spam'])
        self.assertEqual(len(new),3457)
        self.assertEqual(a['development'],b['development'])
        self.assertEqual(sum('cong 500 diem do ' in r['text'] for r in new),1)


class OptimizerParityTests(unittest.TestCase):
    def test_real_sam_update_matches_manual_weighted_grouped_loss(self):
        import torch
        from train_mmbert import train_model
        from training_optimization import parameter_groups
        from sharpness_aware import sam_perturbation
        from filter_policy import install_loss, identity
        import replay_distillation as replay
        class Model(torch.nn.Module):
            def __init__(self):
                super().__init__(); self.linear=torch.nn.Linear(1,4)
            def forward(self,input_ids):return SimpleNamespace(logits=self.linear(input_ids))
        torch.manual_seed(34); model=Model(); manual=copy.deepcopy(model); teacher=copy.deepcopy(model).requires_grad_(False)
        data=rows(); spec=build_spec(data,'sha')
        tokenize=lambda texts,**kw:{'input_ids':torch.tensor([[float(t)/20] for t in texts])}
        args=SimpleNamespace(num_epochs=1,seed=7,max_length=2,boundary_loss_weight=1.,train_label_rows=[],
            selected_label_loss_weight=1.,batch_size=len(data),learning_rate=.01,weight_decay=.01,
            label_smoothing=0.,warmup_ratio=0.,early_stopping_patience=0,sam_rho=.005,max_grad_norm=5.,
            replay_new_source_prefix=['reviewed'],replay_new_loss_weight=1.,replay_alpha=.9,
            replay_temperature=2.,replay_only_correct_teacher=True,replay_agreement_all_rows=True)
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'weights.json';path.write_text(json.dumps(spec))
            restore_weights=install(path,True);restore_loss=install_loss(LABELS)
            try:
                summary={};train_model(model,tokenize,data,LABELS,args,'cpu',replay_teacher=teacher,optimization_summary=summary)
                groups,_=parameter_groups(manual,.01,.01);opt=torch.optim.AdamW(groups,lr=.01)
                x=tokenize([r['text'] for r in data])['input_ids'];labels=torch.tensor([LABELS[r['label']] for r in data])
                weights=torch.tensor([spec['entries'][identity(r['text'])]['weight'] for r in data])
                def loss():
                    losses=replay.replay_distillation_loss(manual(x).logits,teacher(x).logits,labels,
                        torch.ones(len(data),dtype=torch.bool),.9,2.,only_correct_teacher=True,agreement_all_rows=True)
                    return (losses*weights).sum()/weights.sum()
                loss().backward()
                with sam_perturbation(list(manual.parameters()),.005):
                    opt.zero_grad(set_to_none=True);loss().backward()
                torch.nn.utils.clip_grad_norm_(manual.parameters(),5.);opt.step()
                for a,b in zip(model.parameters(),manual.parameters()):torch.testing.assert_close(a,b,rtol=1e-6,atol=1e-7)
                self.assertEqual(summary['completedUpdates'],1)
            finally:restore_loss();restore_weights()

    def test_language_probe_preserves_rng_parameters_and_global_objective(self):
        import torch
        from torch.utils.data import DataLoader
        import train_mmbert as train
        import gradient_diagnostics as diagnostics
        torch.manual_seed(19);model=torch.nn.Linear(1,1);data=rows()
        tokenize=lambda texts,**kw:{'input_ids':torch.tensor([[float(t)/20] for t in texts])}
        loader=DataLoader(train.TextDataset(data,LABELS),batch_size=5,shuffle=False,
            collate_fn=train.make_collate(tokenize,2),generator=torch.Generator().manual_seed(0))
        def terms(b):
            w=b['loss_weights'];return ((model(b['input_ids']).flatten()-b['labels'])**2*w).sum(),w.sum(),len(w)
        expected=diagnostics.full_gradient_probe(model,loader,terms,'cpu')
        rng=torch.get_rng_state().clone();before=[p.clone() for p in model.parameters()]
        restore=install_language_probes(data)
        try:
            actual=diagnostics.full_gradient_probe(model,loader,terms,'cpu')
            reversed_loader=DataLoader(train.TextDataset(list(reversed(data)),LABELS),batch_size=5,
                collate_fn=train.make_collate(tokenize,2))
            with self.assertRaisesRegex(ValueError,'registered training order'):
                diagnostics.full_gradient_probe(model,reversed_loader,terms,'cpu')
        finally:restore()
        for key,value in expected.items():self.assertEqual(actual[key],value)
        self.assertEqual(sum(g['rows'] for g in actual['byLanguageDataObjective'].values()),len(data))
        self.assertTrue(torch.equal(rng,torch.get_rng_state()))
        for a,b in zip(before,model.parameters()):torch.testing.assert_close(a,b,rtol=0,atol=0)


class SelectionTests(unittest.TestCase):
    def test_aggregate_gain_cannot_hide_language_recall_regression(self):
        m={'normalToJunk':1,'normalToPromotion':0,'normalToFiltered':1,'harmfulRecall':.9,
           'harmfulCaught':9,'actionCorrect':90,'normalFineCorrect':80}
        b={'epoch':0,'policy':m,'byLanguage':{'ja':{'normalToJunk':0,'normalToPromotion':0,'harmfulCaught':5},
            'vi':{'normalToJunk':1,'normalToPromotion':0,'harmfulCaught':4}},'macroLanguageActionAccuracy':.9}
        bad=copy.deepcopy(b);bad['epoch']=18;bad['policy']['harmfulCaught']=10;bad['policy']['harmfulRecall']=1.
        bad['byLanguage']['ja']['harmfulCaught']=4;bad['byLanguage']['vi']['harmfulCaught']=6
        self.assertFalse(eligible(bad,b));self.assertEqual(select([b,bad])[0]['epoch'],0)
        b['policy']['normalToJunk']=3;b['byLanguage']['vi']['normalToJunk']=3
        chosen,_,found=select([b]);self.assertEqual(chosen['epoch'],0);self.assertFalse(found)


if __name__=='__main__':unittest.main()
