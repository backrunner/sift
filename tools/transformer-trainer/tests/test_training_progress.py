import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from training_progress import ConvergenceMonitor


class ConvergenceTests(unittest.TestCase):
    def test_plateau_waits_for_minimum_updates(self):
        monitor=ConvergenceMonitor(patience=2,minimum_updates=100)
        self.assertIsNone(monitor.update(1.,.5,10))
        self.assertIsNone(monitor.update(1.,.5,20))
        self.assertIsNone(monitor.update(1.,.5,90))
        self.assertEqual(monitor.update(1.,.5,100),'development_plateau')

    def test_improvement_resets_patience_including_accumulated_small_gains(self):
        monitor=ConvergenceMonitor(patience=3,minimum_updates=0,nll_delta=.01)
        for nll in (1.,.996,.992,.988,.984,.980,.976):
            self.assertIsNone(monitor.update(nll,.5,100))
        self.assertLess(monitor.stale,3)

    def test_clear_divergence_stops_before_minimum_budget(self):
        monitor=ConvergenceMonitor(minimum_updates=1500)
        monitor.update(1.,.5,20)
        self.assertIsNone(monitor.update(1.3,.5,40))
        self.assertIsNone(monitor.update(1.4,.5,60))
        self.assertEqual(monitor.update(1.5,.5,80),'development_nll_divergence')

    def test_macro_progress_can_extend_training_but_not_override_divergence(self):
        monitor=ConvergenceMonitor(patience=2,minimum_updates=0)
        for i in range(5):self.assertIsNone(monitor.update(1.,.5+i*.01,i*100))
        for i in range(2):self.assertIsNone(monitor.update(2.,.6+i*.01,600+i))
        self.assertEqual(monitor.update(2.,.7,700),'development_nll_divergence')

    def test_invalid_values_fail(self):
        for nll,score in [(float('nan'),.5),(float('inf'),.5),(-1.,.5),(1.,2.)]:
            with self.assertRaises(ValueError):ConvergenceMonitor().update(nll,score,1)


@unittest.skipUnless(importlib.util.find_spec('torch') and importlib.util.find_spec('transformers'),'requires trainer venv')
class ExactStateTests(unittest.TestCase):
    def test_interrupted_rdrop_training_matches_uninterrupted_optimizer_and_rng(self):
        import torch
        import train_mmbert
        import training_progress
        class Tiny(torch.nn.Module):
            def __init__(self):
                super().__init__();self.classifier=torch.nn.Linear(2,2)
                self.frozen=torch.nn.Parameter(torch.ones(2),requires_grad=False)
                self.dropout=torch.nn.Dropout(.2)
            def forward(self,input_ids,**kwargs):
                return SimpleNamespace(logits=self.classifier(self.dropout(input_ids.float())))
        def tokenizer(texts,**kwargs):
            return {'input_ids':torch.tensor([[int(t),1] for t in texts])}
        rows=[{'text':str(i),'label':'a' if i%2 else 'b','source':'reviewed'} for i in range(1,6)]
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);data=root/'data.ndjson';data.write_text(''.join(json.dumps(r)+'\n' for r in rows))
            args=SimpleNamespace(num_epochs=3,seed=17,max_length=2,batch_size=2,
                learning_rate=.01,weight_decay=.01,label_smoothing=.02,warmup_ratio=.2,
                boundary_loss_weight=1.,train_label_rows=[],selected_label_loss_weight=1.,
                early_stopping_patience=0,action_loss_weight=0.,rdrop_alpha=1.,
                gradient_probe_every=1,parameter_anchor_weight=.2,
                training_state=root/'full.pt',resume_training_state=None,input=data,
                validation_input=None,replay_teacher=None)
            torch.manual_seed(11);initial=Tiny();full=copy.deepcopy(initial);interrupted=copy.deepcopy(initial)
            torch.manual_seed(29)
            train_mmbert.train_model(full,tokenizer,rows,{'a':0,'b':1},args,'cpu')
            real_save=training_progress.save_state
            class Interrupted(Exception):pass
            def save_then_interrupt(*pos,**kw):
                real_save(*pos,**kw)
                if pos[6]['nextEpoch']==1:raise Interrupted()
            args.training_state=root/'interrupted.pt'
            torch.manual_seed(29)
            with patch.object(training_progress,'save_state',side_effect=save_then_interrupt):
                with self.assertRaises(Interrupted):train_mmbert.train_model(interrupted,tokenizer,rows,{'a':0,'b':1},args,'cpu')
            resumed=copy.deepcopy(initial);args.resume_training_state=args.training_state
            optimization={}
            train_mmbert.train_model(resumed,tokenizer,rows,{'a':0,'b':1},args,'cpu',optimization_summary=optimization)
            for a,b in zip(full.parameters(),resumed.parameters()):torch.testing.assert_close(a,b,rtol=0,atol=0)
            self.assertTrue(optimization['stateResumed'])
            self.assertEqual(optimization['completedUpdates'],9)
            state=torch.load(args.training_state,weights_only=True)
            self.assertEqual(state['scheduler']['last_epoch'],9)
            self.assertTrue(state['optimizer']['state'])
            with self.assertRaisesRegex(ValueError,'already stopped'):
                train_mmbert.train_model(copy.deepcopy(initial),tokenizer,rows,{'a':0,'b':1},args,'cpu')
            args.learning_rate=.02
            with self.assertRaisesRegex(ValueError,'contract changed'):
                train_mmbert.train_model(copy.deepcopy(initial),tokenizer,rows,{'a':0,'b':1},args,'cpu')


if __name__=='__main__':unittest.main()
