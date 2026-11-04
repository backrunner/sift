"""Frozen asymmetric head objective and external selection policy."""
from action_head_v67 import per_row_loss


def loss(logits, labels, normal_filter_cost=2.):
    import torch
    base = per_row_loss(logits, labels)
    if normal_filter_cost == 0: return base
    if normal_filter_cost != 2.: raise ValueError('only the preregistered cost comparison is supported')
    # -log P(business OR ordinary), stable even when filtering mass is near1.
    filtering_risk = torch.logsumexp(logits, -1) - torch.logsumexp(logits[:, [0, 1]], -1)
    return base + torch.where(labels < 2, 2. * filtering_risk, torch.zeros_like(base))


def eligible(candidate, baseline, *, fresh=True):
    m, b = candidate['policy'], baseline['policy']
    if set(candidate['byLanguage']) != set(baseline['byLanguage']):
        raise ValueError('language membership changed')
    for x, y in [(m, b), *[(candidate['byLanguage'][k], baseline['byLanguage'][k]) for k in baseline['byLanguage']]]:
        if (x['normalToJunk'] > y['normalToJunk'] or x['normalToPromotion'] > y['normalToPromotion']
                or x['harmfulCaught'] < y['harmfulCaught'] or x['commercialCaught'] < y['commercialCaught']):
            return False
    if candidate.get('protectedFineChanges', 0) or candidate.get('junkDowngrades', 0): return False
    if fresh:
        return (m['normalToJunk'] == 0 and m['normalToPromotion'] == 0
                and m['policyActionAccuracy'] >= .90 and m['harmfulRecall'] >= .90
                and m['actionCorrect'] >= b['actionCorrect'])
    return m['normalToJunk'] <= 2 and m['actionCorrect'] >= b['actionCorrect'] - int(.005 * m['scored'])


def select(records):
    if [r['epoch'] for r in records] != list(range(19)):
        raise ValueError('exactly eighteen epochs plus baseline required')
    baseline = records[0]
    feasible = [r for r in records[1:] if eligible(r, baseline)
                and (r['policy']['harmfulCaught'] > baseline['policy']['harmfulCaught']
                     or r['policy']['actionCorrect'] > baseline['policy']['actionCorrect'])]
    if not feasible: return baseline
    return max(feasible, key=lambda r: (r['policy']['harmfulCaught'], r['policy']['actionCorrect'], -r['epoch']))
