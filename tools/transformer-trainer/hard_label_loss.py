"""Per-row supervised CE or focal loss; no inference threshold changes."""
import math


def supervised_loss(logits, labels, *, label_smoothing=0., focal_gamma=0.):
    import torch
    import torch.nn.functional as F
    if not math.isfinite(focal_gamma) or focal_gamma < 0:
        raise ValueError('focal gamma must be finite and nonnegative')
    if focal_gamma and label_smoothing:
        raise ValueError('focal loss requires unsmoothed hard labels')
    ce=F.cross_entropy(logits,labels,reduction='none',label_smoothing=label_smoothing)
    if not focal_gamma:
        return ce
    # 1-exp(-CE) computed accurately for high-confidence examples. Do not
    # detach this factor: focal loss includes its gradient, not just weighting.
    factor=(-(-ce).expm1()).clamp_min(torch.finfo(ce.dtype).tiny)
    return factor.pow(focal_gamma)*ce
