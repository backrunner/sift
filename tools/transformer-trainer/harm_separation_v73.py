"""Keep commercial/harmful supervision identifiable without changing action scoring."""
from expert_routing_v71 import safety


def separated_loss(logits,labels):
    import torch
    import torch.nn.functional as F
    # Evaluation can tolerate commercial -> junk; supervision still identifies
    # harmful intent. Otherwise a head can drive commercial probability to zero.
    base=F.cross_entropy(logits,labels,reduction='none')
    normal_risk=torch.logsumexp(logits,-1)-torch.logsumexp(logits[:,[0,1]],-1)
    return base+torch.where(labels<2,2.*normal_risk,torch.zeros_like(base))


def eligible(candidate,baseline):
    return (safety(candidate,baseline,'historical')
            and candidate['policy']['policyActionAccuracy']>=.97
            and candidate['policy']['harmfulRecall']>=.90)


def select(records):
    if [r['epoch'] for r in records]!=list(range(19)):raise ValueError('baseline plus18 epochs required')
    b=records[0]
    # User accepts about97%; accuracy alone cannot waive normal/harmful gates.
    candidates=[r for r in records[1:] if eligible(r,b)
                and r['policy']['actionCorrect']>b['policy']['actionCorrect']]
    return max(candidates,key=lambda r:(r['policy']['harmfulCaught'],r['policy']['actionCorrect'],-r['epoch'])) if candidates else b
