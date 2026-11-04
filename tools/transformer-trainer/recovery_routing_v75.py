"""Preregistered frozen-representation gate ablations; no deployment defaults."""
import math

from expert_routing_v71 import features, safety

ARMS=('old-joint','data-joint','data-directional','semantic-linear','semantic-mlp')
BRANCHES=('recovery','escalation','refinement')
EPOCHS=36


def folds(rows):
    families={}
    for prefix,number in (('authored-reviewed-v66:',6),('authored-reviewed-v69:',6),('authored-reviewed-v75:',18)):
        groups=sorted({r['familyId'] for r in rows if r['source'].startswith(prefix)})
        if len(groups)!=number:raise ValueError('unexpected fitting families')
        for i,g in enumerate(groups):
            if g in families:raise ValueError('family crossed sources')
            members=[r for r in rows if r['familyId']==g]
            if len(members)!=12 or any(sum(r['language']==lang for r in members)!=4 for lang in ('zh','en','ja')):
                raise ValueError('incomplete multilingual contrast family')
            families[g]=i%3
    if set(families)!={r['familyId'] for r in rows}:raise ValueError('unsupported source')
    return [families[r['familyId']] for r in rows]


def gate(arm,seed):
    import torch
    if arm not in ARMS:raise ValueError('unknown arm')
    torch.manual_seed(seed)
    width=402 if arm.startswith('semantic') else 18
    outputs=1 if arm.endswith('joint') else 3
    if arm=='semantic-mlp':
        g=torch.nn.Sequential(torch.nn.Linear(width,32),torch.nn.GELU(),torch.nn.Linear(32,outputs))
        last=g[-1]
    else:g=torch.nn.Linear(width,outputs);last=g
    torch.nn.init.zeros_(last.weight);torch.nn.init.constant_(last.bias,-math.log(9))
    return g


def inputs(arm,full,heads,vectors,actions):
    import torch
    x=features(full,heads,actions)
    if vectors.shape!=(len(full),384) or not torch.isfinite(vectors).all():raise ValueError('invalid frozen features')
    if arm.startswith('semantic'):
        x=torch.cat([x,torch.nn.functional.normalize(vectors.float(),p=2,dim=-1)],-1)
    return x


def branch_indices(decisions):
    import torch
    return torch.tensor([BRANCHES.index(d['modelRoutingBranch']) for d in decisions])


def objective(g,x,y,w,branches):
    import torch
    logits=g(x)
    chosen=logits[:,0] if logits.shape[-1]==1 else logits.gather(1,branches[:,None]).squeeze(1)
    risk=(torch.nn.functional.binary_cross_entropy_with_logits(chosen,y,reduction='none')*w).sum()/w.sum()
    # Same coefficient and sum-of-squares convention for each ablation.
    return risk+.01*sum(v.square().sum() for n,v in g.named_parameters() if n.endswith('weight'))


def preferences(g,x):
    import torch
    with torch.no_grad():p=g(x).double().sigmoid()
    if p.shape[1]==1:p=p.expand(-1,3)
    return [dict(zip(BRANCHES,v,strict=True)) for v in p.tolist()]


def eligible(candidate,baseline):
    return safety(candidate,baseline,'historical') and candidate['policy']['policyActionAccuracy']>=.97 and candidate['policy']['harmfulRecall']>=.90


def select(records):
    if [r['epoch'] for r in records]!=list(range(EPOCHS+1)):raise ValueError('baseline and36 epochs required')
    b=records[0]
    valid=[r for r in records[1:] if eligible(r,b) and r['policy']['actionCorrect']>b['policy']['actionCorrect']]
    return max(valid,key=lambda r:(r['policy']['harmfulCaught'],r['policy']['actionCorrect'],-r['epoch'])) if valid else b
