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
from loss_tail import LossTailScheduler


@unittest.skipUnless(importlib.util.find_spec('torch'),'requires trainer venv')
class LossTailTests(unittest.TestCase):
    def scheduler(self,maximum=8):
        import torch
        a=torch.nn.Parameter(torch.ones(1));b=torch.nn.Parameter(torch.ones(1))
        optimizer=torch.optim.AdamW([{'params':[a],'lr':.02},{'params':[b],'lr':.04}])
        return LossTailScheduler(optimizer,nominal_epochs=2,updates_per_epoch=2,warmup_updates=1,
            extension_epochs=2,max_extension_epochs=maximum,tail_ratio=.2,patience=3)

    def epoch(self,scheduler,epoch,loss):
        for _ in range(2):scheduler.optimizer.step();scheduler.step()
        return scheduler.finish_epoch(epoch,loss)

    def test_decreasing_loss_extends_budget_at_nonzero_lr_and_preserves_group_ratios(self):
        s=self.scheduler()
        self.epoch(s,1,1.);event=self.epoch(s,2,.8)
        self.assertEqual(event['extendedToEpoch'],4)
        self.assertAlmostEqual(s.get_last_lr()[0],.004)
        for epoch in range(3,7):
            self.epoch(s,epoch,.8-.08*(epoch-2))
            self.assertGreater(s.get_last_lr()[0],0)
            self.assertAlmostEqual(s.get_last_lr()[1]/s.get_last_lr()[0],2.)
        self.assertEqual(s.active_epoch_limit,8)

    def test_plateau_requires_a_further_window_after_lowering_lr(self):
        s=self.scheduler();events=[]
        for epoch,loss in enumerate([1.,.8,.6,.4,.3,.3,.3,.3,.3,.3],1):
            events.append(self.epoch(s,epoch,loss))
            if epoch==7:
                self.assertEqual(events[-1]['decision'],'reduce_lr_to_confirm_plateau')
                self.assertIsNone(s.stop_reason);self.assertAlmostEqual(s.get_last_lr()[0],.002)
            if epoch in (8,9):self.assertIsNone(s.stop_reason)
        self.assertEqual(s.stop_reason,'training_objective_plateau_after_lr_reduction')

    def test_exhausted_budget_is_not_reported_as_convergence(self):
        s=self.scheduler(maximum=2)
        for epoch,loss in enumerate([1.,.8,.6,.4],1):self.epoch(s,epoch,loss)
        self.assertEqual(s.stop_reason,'adaptive_budget_exhausted_unconverged')

    def test_controller_state_restores_pending_confirmation_and_lr(self):
        s=self.scheduler()
        for epoch,loss in enumerate([1.,.8,.8,.8],1):self.epoch(s,epoch,loss)
        state=s.state_dict();other=self.scheduler();other.load_state_dict(state)
        self.assertEqual(other.get_last_lr(),s.get_last_lr())
        for epoch in (5,6,7):
            self.assertEqual(self.epoch(other,epoch,.8),self.epoch(s,epoch,.8))
        self.assertEqual(other.state_dict(),s.state_dict())

    def test_invalid_objective_or_partial_epoch_cannot_extend(self):
        s=self.scheduler()
        with self.assertRaises(ValueError):s.finish_epoch(1,float('nan'))
        with self.assertRaises(ValueError):s.finish_epoch(1,1.)

    def test_changed_scheduler_contract_is_rejected(self):
        s=self.scheduler();state=s.state_dict();state['tail_ratio']=.3
        with self.assertRaisesRegex(ValueError,'plan changed'):s.load_state_dict(state)

    def test_real_training_extends_resumes_exactly_and_restores_best_epoch(self):
        import torch
        import train_mmbert,training_progress
        class Tiny(torch.nn.Module):
            def __init__(self):super().__init__();self.classifier=torch.nn.Linear(2,2)
            def forward(self,input_ids,**kw):return SimpleNamespace(logits=self.classifier(input_ids.float()))
        def tokenizer(texts,**kw):return {'input_ids':torch.tensor([[int(t),1] for t in texts])}
        rows=[{'text':str(i),'label':'a' if i%2 else 'b','source':'reviewed'} for i in range(1,6)]
        def evaluation(*pos,**kw):
            return (.5,{},[('a','a'),('b','a')],[{'negativeLogLikelihood':1.},{'negativeLogLikelihood':1.}])
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);data=root/'data.ndjson';data.write_text(''.join(json.dumps(r)+'\n' for r in rows))
            args=SimpleNamespace(num_epochs=2,seed=17,max_length=2,batch_size=2,
                learning_rate=.01,weight_decay=.01,label_smoothing=0.,warmup_ratio=.2,
                boundary_loss_weight=1.,train_label_rows=[],selected_label_loss_weight=1.,
                early_stopping_patience=2,early_stopping_delta=0.,diagnostic_best_fallback=True,
                convergence_patience=2,convergence_min_updates=0,gradient_probe_every=1,
                parameter_anchor_weight=.1,loss_tail_epochs=2,loss_tail_max_epochs=4,
                loss_tail_lr_ratio=.2,loss_tail_patience=3,save_epoch_parameters=True,
                out=root/'full',training_state=root/'full/state.pt',resume_training_state=None,
                input=data,validation_input=data,replay_teacher=None)
            torch.manual_seed(31);initial=Tiny();full=copy.deepcopy(initial)
            def run(model,summary,history):
                with patch.object(train_mmbert,'evaluate_model',side_effect=evaluation):
                    train_mmbert.train_model(model,tokenizer,rows,{'a':0,'b':1},args,'cpu',
                        validation_rows=rows,selection_history=history,
                        validation_actions={'a':'allow','b':'junk'},optimization_summary=summary)
            full_summary={};run(full,full_summary,[])
            self.assertGreater(full_summary['completedUpdates'],6)
            self.assertEqual(full_summary['selectedCheckpointEpoch'],1)
            first=torch.load(root/'full/epochs/epoch-001.pt',weights_only=True)['parameters']
            for n,p in full.named_parameters():torch.testing.assert_close(p,first[n],rtol=0,atol=0)
            full_state=torch.load(args.training_state,weights_only=True)
            self.assertTrue(any(not torch.equal(first[n],p) for n,p in full_state['parameters'].items()))
            real_save=training_progress.save_state
            class Interrupted(Exception):pass
            def save_interrupt(*pos,**kw):
                real_save(*pos,**kw)
                if pos[6]['nextEpoch']==3:raise Interrupted()
            args.out=root/'interrupted';args.training_state=args.out/'state.pt'
            with patch.object(training_progress,'save_state',side_effect=save_interrupt):
                with self.assertRaises(Interrupted):run(copy.deepcopy(initial),{},[])
            args.resume_training_state=args.training_state;resumed=copy.deepcopy(initial);summary={}
            run(resumed,summary,[])
            state=torch.load(args.training_state,weights_only=True)
            for n,p in full_state['parameters'].items():torch.testing.assert_close(p,state['parameters'][n],rtol=0,atol=0)
            for a,b in zip(full.parameters(),resumed.parameters()):torch.testing.assert_close(a,b,rtol=0,atol=0)
            self.assertEqual(summary['lossTail'],full_summary['lossTail'])
            self.assertEqual(state['scheduler'],full_state['scheduler'])
            for a,b in zip(state['optimizer']['state'].values(),full_state['optimizer']['state'].values()):
                for name,value in a.items():torch.testing.assert_close(value,b[name],rtol=0,atol=0)
            # Allowing loss-tail progress must not bypass the development
            # divergence veto, even when training loss keeps falling.
            development_losses=iter([1.,1.5,1.5,1.5])
            def evaluation(*pos,**kw):
                nll=next(development_losses)
                return (.5,{},[('a','a'),('b','a')],
                        [{'negativeLogLikelihood':nll},{'negativeLogLikelihood':nll}])
            args.resume_training_state=None;args.out=root/'divergent'
            args.training_state=args.out/'state.pt';divergent_summary={}
            run(copy.deepcopy(initial),divergent_summary,[])
            self.assertEqual(divergent_summary['stopReason'],'development_nll_divergence')
            self.assertEqual(divergent_summary['completedUpdates'],12)
            self.assertEqual(divergent_summary['selectedCheckpointEpoch'],1)


if __name__=='__main__':unittest.main()
