"""Frozen-representation action supervision; it may only authorize business mass."""
import math
from action_calibration_v66 import safe

BUSINESS, ORDINARY, COMMERCIAL, HARMFUL = range(4)


def target(label, actions):
    return {'transaction': BUSINESS, 'none': ORDINARY, 'promotion': COMMERCIAL, 'junk': HARMFUL}[actions[label]]


def per_row_loss(logits, labels):
    import torch
    import torch.nn.functional as F
    ordinary = F.cross_entropy(logits, labels, reduction='none')
    commercial = torch.logsumexp(logits, -1) - torch.logsumexp(logits[:, [COMMERCIAL, HARMFUL]], -1)
    return torch.where(labels == COMMERCIAL, commercial, ordinary)


def gated_predictions(predictions, action_probabilities):
    if len(predictions) != len(action_probabilities): raise ValueError('head prediction alignment changed')
    output = []
    for row, values in zip(predictions, action_probabilities, strict=True):
        if (len(values) != 4 or any(not math.isfinite(v) or not 0 <= v <= 1 for v in values)
                or abs(sum(values) - 1) > 1e-6):
            raise ValueError('invalid four-action probability distribution')
        # Raw labels, confidence and all fine probabilities stay unchanged.
        # A head cannot directly promote to junk/promotion or rescue a nonbusiness top leaf.
        output.append(row if values[BUSINESS] >= .90 else {k: v for k, v in row.items() if k != 'probabilities'})
    return output


def eligible(record):
    p = record['policy']
    return safe(record['comparison']) and p['policyActionAccuracy'] >= .90 and p['harmfulRecall'] >= .90


def select_epoch(records):
    if [r['epoch'] for r in records] != list(range(19)):
        raise ValueError('complete epoch-zero plus eighteen-epoch evidence required')
    accepted = [r for r in records[1:] if eligible(r) and r['comparison']['recovered']]
    rank = lambda r: (r['policy']['actionCorrect'], -r['headDevelopmentLoss'], -r['epoch'])
    return max(accepted, key=rank) if accepted else records[0]
