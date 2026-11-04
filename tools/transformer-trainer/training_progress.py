"""Bounded convergence monitoring and resumable optimizer/RNG state."""
from dataclasses import asdict,dataclass
import hashlib
import math
from pathlib import Path
import random


@dataclass
class ConvergenceMonitor:
    patience: int = 6
    minimum_updates: int = 1500
    nll_delta: float = .005
    score_delta: float = .002
    divergence_delta: float = .2
    divergence_patience: int = 3
    best_nll: float | None = None
    best_score: float | None = None
    progress_nll: float | None = None
    progress_score: float | None = None
    stale: int = 0
    divergent: int = 0

    def update(self,nll,score,updates):
        if not math.isfinite(nll) or nll<0 or not math.isfinite(score) or not 0<=score<=1:
            raise ValueError('non-finite/invalid development convergence metric')
        nll_improved=self.progress_nll is None or nll<self.progress_nll-self.nll_delta
        score_improved=self.progress_score is None or score>self.progress_score+self.score_delta
        improved=nll_improved or score_improved
        if nll_improved:self.progress_nll=nll
        if score_improved:self.progress_score=score
        self.stale=0 if improved else self.stale+1
        self.best_nll=nll if self.best_nll is None else min(nll,self.best_nll)
        self.best_score=score if self.best_score is None else max(score,self.best_score)
        self.divergent=self.divergent+1 if nll>self.best_nll+self.divergence_delta else 0
        if self.divergent>=self.divergence_patience:return 'development_nll_divergence'
        if updates>=self.minimum_updates and self.stale>=self.patience:return 'development_plateau'
        return None


def frozen_sha256(model):
    digest=hashlib.sha256()
    for name,parameter in model.named_parameters():
        if not parameter.requires_grad:
            digest.update(name.encode());digest.update(parameter.detach().cpu().contiguous().numpy().tobytes())
    return digest.hexdigest()


def cpu_tree(value):
    import torch
    if isinstance(value,torch.Tensor):return value.detach().cpu().clone()
    if isinstance(value,dict):return {k:cpu_tree(v) for k,v in value.items()}
    if isinstance(value,list):return [cpu_tree(v) for v in value]
    if isinstance(value,tuple):return tuple(cpu_tree(v) for v in value)
    return value


def save_state(path,model,optimizer,scheduler,generator,contract,extra,device):
    import torch
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    state={'schemaVersion':1,'contract':contract,
        'parameters':{n:p.detach().cpu().clone() for n,p in model.named_parameters() if p.requires_grad},
        'optimizer':cpu_tree(optimizer.state_dict()),'scheduler':scheduler.state_dict(),
        'generatorRNG':generator.get_state(),'torchRNG':torch.get_rng_state(),
        'pythonRNG':random.getstate(),'extra':cpu_tree(extra)}
    if device=='mps':state['mpsRNG']=torch.mps.get_rng_state()
    if device=='cuda':state['cudaRNG']=torch.cuda.get_rng_state_all()
    temp=path.with_suffix(path.suffix+'.tmp');torch.save(state,temp);temp.replace(path)


def load_state(path,model,optimizer,scheduler,generator,contract,device):
    import torch
    state=torch.load(path,map_location='cpu',weights_only=True)
    if state.get('schemaVersion')!=1 or state['contract']!=contract:
        raise ValueError('training-state contract changed: inputs, frozen weights, labels, schedule or method differ')
    current={n:p for n,p in model.named_parameters() if p.requires_grad}
    if set(current)!=set(state['parameters']):raise ValueError('trainable parameter contract changed')
    with torch.no_grad():
        for n,p in current.items():p.copy_(state['parameters'][n].to(p.device,p.dtype))
    # Scheduler exists before optimizer state is loaded; both counters and LRs
    # resume instead of resetting the completed warmup/decay schedule.
    optimizer.load_state_dict(state['optimizer']);scheduler.load_state_dict(state['scheduler'])
    generator.set_state(state['generatorRNG']);torch.set_rng_state(state['torchRNG']);random.setstate(state['pythonRNG'])
    if device=='mps':torch.mps.set_rng_state(state['mpsRNG'])
    if device=='cuda':torch.cuda.set_rng_state_all(state['cudaRNG'])
    return state['extra']
