"""Low-capacity confidence features, family folds and risk-weighted expert targets."""
import math

ORDER=('business','ordinary','commercial','harmful')
ACTION_INDEX={'transaction':0,'none':1,'promotion':2,'junk':3}


def folds(rows):
    groups={r['familyId'] for r in rows}
    assignment={}
    for source in ('authored-reviewed-v66:','authored-reviewed-v69:'):
        families=sorted({r['familyId'] for r in rows if r['source'].startswith(source)})
        if len(families)!=6:raise ValueError('expected6 families per authored fitting source')
        assignment.update({g:i%3 for i,g in enumerate(families)})
    if set(assignment)!=groups:raise ValueError('unsupported family source')
    for g in groups:
        members=[r for r in rows if r['familyId']==g]
        if len(members)!=12 or {r['language'] for r in members}!={'zh','en','ja'}:raise ValueError('incomplete family')
    return [assignment[r['familyId']] for r in rows]


def features(full,heads,actions):
    import torch
    labels=sorted(full[0]['probabilities'])
    fine=torch.tensor([[r['probabilities'][k] for k in labels] for r in full],dtype=torch.float64)
    head=torch.tensor([[h[k] for k in ORDER] for h in heads],dtype=torch.float64)
    if not torch.isfinite(fine).all() or not torch.isfinite(head).all():raise ValueError('nonfinite distribution')
    if (fine<0).any() or (head<0).any() or not torch.allclose(fine.sum(-1),torch.ones(len(fine),dtype=fine.dtype),atol=.001):raise ValueError('invalid fine distribution')
    if not torch.allclose(head.sum(-1),torch.ones(len(head),dtype=head.dtype),atol=.001):raise ValueError('invalid head distribution')
    fine=fine/fine.sum(-1,keepdim=True);head=head/head.sum(-1,keepdim=True)
    index=torch.tensor([ACTION_INDEX[actions[k]] for k in labels])
    coarse=torch.stack([fine[:,index==i].sum(-1) for i in range(4)],-1)
    top=fine.topk(2,-1).values;htop=head.topk(2,-1).values
    fine_class=index[fine.argmax(-1)];onehot=torch.nn.functional.one_hot(fine_class,4).to(fine.dtype)
    entropy=-(fine*fine.clamp_min(1e-12).log()).sum(-1)/math.log(len(labels))
    head_entropy=-(head*head.clamp_min(1e-12).log()).sum(-1)/math.log(4)
    numeric=torch.stack([top[:,0],top[:,0]-top[:,1],entropy,htop[:,0]-htop[:,1],head_entropy,
                         (fine_class!=head.argmax(-1)).to(fine.dtype)],-1)
    return torch.cat([coarse,head,numeric,onehot],-1).float()


def cost(row,decision,actions):
    kind=row['filterReview']['kind'];action=decision['engineAction']
    if kind=='commercial':return 0 if action in ('promotion','junk') else 1
    if kind=='harmful':return 0 if action=='junk' else 5
    if kind!='normal':raise ValueError('unresolved/scenario rows cannot fit expert gate')
    if action==actions[row['label']]:return 0
    return 5 if action in ('promotion','junk') else 1


def targets(rows,fine,head,actions):
    import torch
    delta=[cost(r,f,actions)-cost(r,h,actions) for r,f,h in zip(rows,fine,head,strict=True)]
    # Ties mildly favor original fine behavior instead of forcing changes.
    return (torch.tensor([d>0 for d in delta],dtype=torch.float32),
            torch.tensor([abs(d) if d else .1 for d in delta],dtype=torch.float32))


def safety(candidate,baseline,role='fresh'):
    m,b=candidate['policy'],baseline['policy']
    for k in ('harmfulLost','normalNewJunk','normalNewPromotion'):
        if candidate[k]:return False
    if set(candidate['byLanguage'])!=set(baseline['byLanguage']):raise ValueError('language drift')
    for lang,x in candidate['byLanguage'].items():
        y=baseline['byLanguage'][lang]
        if x['harmfulCaught']<y['harmfulCaught'] or x['commercialCaught']<y['commercialCaught']:return False
    if role=='fresh':return m['normalToJunk']==0 and m['normalToPromotion']==0 and m['policyActionAccuracy']>=.90 and m['harmfulRecall']>=.90
    if role=='boundary':return m['normalToJunk']<=2 and m['normalToPromotion']<=b['normalToPromotion'] and m['policyActionAccuracy']>=.90
    if role!='historical':raise ValueError('invalid role')
    return m['normalToJunk']<=min(2,b['normalToJunk']) and m['normalToPromotion']<=b['normalToPromotion'] and m['actionCorrect']>=b['actionCorrect']-int(.005*m['scored'])


def select(records):
    if [r['epoch'] for r in records]!=list(range(19)):raise ValueError('baseline and18 epochs required')
    b=records[0];eligible=[r for r in records[1:] if safety(r,b) and r['policy']['actionCorrect']>=b['policy']['actionCorrect']
        and (r['policy']['actionCorrect']>b['policy']['actionCorrect'] or r['policy']['harmfulCaught']>b['policy']['harmfulCaught'] or r['policy']['normalToJunk']<b['policy']['normalToJunk'])]
    return max(eligible,key=lambda r:(r['policy']['harmfulCaught'],r['policy']['actionCorrect'],-r['epoch'])) if eligible else b
