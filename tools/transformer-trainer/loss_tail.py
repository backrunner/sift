"""Bounded loss-driven continuation with nonzero LR and exact-resume state.

The nominal warmup/decay budget ends at a nonzero LR. Extend epochs in blocks
while the full training objective is improving. Confirm a plateau across two
LR levels before calling it converged under the declared tolerance.
"""
import copy
import math


class LossTailScheduler:
    def __init__(self,optimizer,*,nominal_epochs,updates_per_epoch,warmup_updates,
                 extension_epochs,max_extension_epochs,tail_ratio=.1,patience=6):
        if (min(nominal_epochs,updates_per_epoch,extension_epochs)>=1
                and max_extension_epochs>=extension_epochs and patience>=3
                and 0<tail_ratio<=1 and 0<=warmup_updates<nominal_epochs*updates_per_epoch):
            pass
        else:raise ValueError('invalid adaptive loss-tail plan')
        self.optimizer=optimizer
        self.base_lrs=[g['lr'] for g in optimizer.param_groups]
        self.nominal_epochs=nominal_epochs;self.updates_per_epoch=updates_per_epoch
        self.nominal_updates=nominal_epochs*updates_per_epoch
        self.warmup_updates=warmup_updates
        self.extension_epochs=extension_epochs
        self.maximum_epochs=nominal_epochs+max_extension_epochs
        self.active_epoch_limit=nominal_epochs
        self.tail_ratio=tail_ratio;self.patience=patience
        self.updates=0;self.multiplier=1.;self.reductions=0;self.tail_losses=[]
        self.events=[];self.stop_reason=None;self.nominal_objective=None
        self._apply()

    def _factor(self):
        if self.updates<self.warmup_updates:
            return self.updates/max(1,self.warmup_updates)
        progress=min(1.,max(0.,(self.updates-self.warmup_updates)/
                               (self.nominal_updates-self.warmup_updates)))
        return (1-(1-self.tail_ratio)*progress)*self.multiplier

    def _apply(self):
        for group,rate in zip(self.optimizer.param_groups,self.base_lrs):
            group['lr']=rate*self._factor()

    def step(self):
        self.updates+=1;self._apply()

    def get_last_lr(self):return [g['lr'] for g in self.optimizer.param_groups]

    def finish_epoch(self,epoch,objective):
        if not math.isfinite(objective) or objective<0:
            raise ValueError('non-finite/invalid full training objective')
        if self.updates!=epoch*self.updates_per_epoch:
            raise ValueError('adaptive tail requires complete epoch boundaries')
        if self.stop_reason:raise ValueError('adaptive tail already stopped')
        event={'epoch':epoch,'objective':objective,'activeEpochLimit':self.active_epoch_limit,
               'learningRates':self.get_last_lr(),'decision':'nominal_training'}
        if epoch==self.nominal_epochs:self.nominal_objective=objective
        if epoch>=self.nominal_epochs:
            self.tail_losses.append(objective);self.tail_losses=self.tail_losses[-self.patience:]
            tolerance=max(.001,.005*max(self.tail_losses))
            width=max(self.tail_losses)-min(self.tail_losses)
            plateau=len(self.tail_losses)==self.patience and width<=tolerance
            event.update(decision='loss_still_progressing',windowChecks=len(self.tail_losses),
                         windowRange=width,tolerance=tolerance,objectivePlateau=plateau)
            if plateau and self.reductions:
                self.stop_reason='training_objective_plateau_after_lr_reduction'
                event['decision']=self.stop_reason
            elif plateau:
                self.multiplier*=.5;self.reductions+=1;self.tail_losses=[]
                self._apply();event.update(decision='reduce_lr_to_confirm_plateau',
                                         nextLearningRates=self.get_last_lr())
            if not self.stop_reason and epoch>=self.active_epoch_limit:
                if epoch>=self.maximum_epochs:
                    self.stop_reason='adaptive_budget_exhausted_unconverged'
                    event['decision']=self.stop_reason
                else:
                    self.active_epoch_limit=min(self.maximum_epochs,epoch+self.extension_epochs)
                    event.update(extendedToEpoch=self.active_epoch_limit)
        self.events.append(event)
        return event

    def state_dict(self):
        return copy.deepcopy({k:v for k,v in self.__dict__.items() if k!='optimizer'})

    def load_state_dict(self,state):
        expected=('base_lrs','nominal_epochs','updates_per_epoch','nominal_updates',
                  'warmup_updates','extension_epochs','maximum_epochs','tail_ratio','patience')
        if any(getattr(self,k)!=state.get(k) for k in expected):
            raise ValueError('adaptive scheduler plan changed')
        self.__dict__.update(copy.deepcopy(state));self._apply()
