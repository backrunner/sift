"""Train-only spam-vs-rest supervision. No inference threshold/ABI changes."""
import math


def positive_weight(labels,spam_id,override=None):
    positives=sum(label==spam_id for label in labels)
    negatives=len(labels)-positives
    if not positives or not negatives:raise ValueError('spam objective requires both positive and negative training rows')
    if override is not None:
        if not math.isfinite(override) or override <= 0:
            raise ValueError('spam positive weight must be finite and positive')
        return float(override)
    return min(3.,max(1.,math.sqrt(negatives/positives)))


def spam_binary_loss(logits,labels,spam_id,weight):
    import torch
    from torch.nn import functional as F
    if logits.shape[-1]<2 or not 0<=spam_id<logits.shape[-1] or not math.isfinite(weight) or weight<=0:
        raise ValueError('invalid spam objective contract')
    logits=logits.float()
    other=torch.cat((logits[:,:spam_id],logits[:,spam_id+1:]),dim=-1)
    binary_logit=logits[:,spam_id]-torch.logsumexp(other,dim=-1)
    return F.binary_cross_entropy_with_logits(binary_logit,(labels==spam_id).float(),
        pos_weight=torch.tensor(weight,device=logits.device,dtype=logits.dtype),reduction='none')
