"""Independent scoring definitions: no imports from the existing metric code."""
from collections import Counter
import hashlib
import re
import unicodedata


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def action_map(taxonomy):
    result = {'__sift_abstain__': 'none'}
    for group in taxonomy['groups']:
        for leaf in group['leaves']:
            result[leaf['id']] = leaf.get('systemAction', group['systemAction'])
    for leaf in taxonomy.get('standalone', []):
        result[leaf['id']] = leaf['systemAction']
    return result


def subaction(label, action):
    # Current advertised IdentityLookup capabilities; unsupported categories -> none.
    if action == 'promotion':
        return 'promotionalOffers' if label in ('promotion', 'carrier.promotion') else 'none'
    if action != 'transaction':
        return 'none'
    if label.startswith('finance.'):
        return 'transactionalFinance'
    if label in ('transaction.order', 'life.takeaway', 'life.express', 'life.logistics', 'life.pickup_code', 'travel.ticketing'):
        return 'transactionalOrders'
    if label in ('work.meeting', 'work.reminder', 'work.training', 'travel.transport'):
        return 'transactionalReminders'
    return 'none'


def score(rows, predictions, actions, prefix='engine'):
    counts = Counter(total=len(rows)); confusion = Counter()
    for i, (row, pred) in enumerate(zip(rows, predictions, strict=True)):
        if row['label'] != pred['label'] or ('text' in pred and pred['text'] != row['text']):
            raise ValueError(f'misaligned prediction {i}')
        review = row['filterReview']; kind = review['kind']
        if kind not in ('normal', 'commercial', 'harmful', 'unresolved'):
            raise ValueError('unknown review kind')
        if kind == 'unresolved':
            counts['excludedUnresolved'] += 1; continue
        if review['inputForm'] == 'scenario-description':
            counts['excludedScenario'] += 1; continue
        expected = actions[row['label']]
        actual = pred[prefix + 'Action']
        if actual not in ('none', 'transaction', 'promotion', 'junk'):
            raise ValueError('unknown action')
        expected_sub = subaction(row['label'], expected)
        if pred.get('expectedSubAction', expected_sub) != expected_sub:
            raise ValueError(f'gold subaction disagreement at {i}')
        counts['actionScored'] += 1; counts[kind] += 1
        strict = expected == actual
        policy = actual in ('promotion', 'junk') if kind == 'commercial' else (actual == 'junk' if kind == 'harmful' else strict)
        counts['policyActionCorrect'] += policy
        counts['strictActionCorrect'] += strict
        counts['nativeRouteCorrect'] += strict and pred[prefix + 'SubAction'] == expected_sub
        counts['harmfulCaught'] += kind == 'harmful' and actual == 'junk'
        counts['normalToJunk'] += kind == 'normal' and actual == 'junk'
        counts['commercialToJunk'] += kind == 'commercial' and actual == 'junk'
        confusion[f'{expected}->{actual}'] += 1
        if review.get('fineLabelScored', False):
            counts['fineScored'] += 1
            counts['fineCorrect'] += pred[prefix + 'Label'] == row['label']
    out = dict(counts)
    for name, numerator, denominator in (
        ('policyActionAccuracy', 'policyActionCorrect', 'actionScored'),
        ('strictActionAccuracy', 'strictActionCorrect', 'actionScored'),
        ('nativeRouteAccuracy', 'nativeRouteCorrect', 'actionScored'),
        ('fineAccuracy', 'fineCorrect', 'fineScored')):
        out[name] = counts[numerator] / counts[denominator] if counts[denominator] else None
    out['actionConfusion'] = dict(confusion)
    return out


def digit_signature(text):
    # Separately implemented, deliberately explicit normalization for audit.
    normalized = unicodedata.normalize('NFKC', text).casefold()
    return re.sub(r'\s+', '', re.sub(r'\d+', '#', normalized))


def composition(rows):
    clusters = {}
    for row in rows:
        clusters.setdefault(digit_signature(row['text']), []).append(row)
    return dict(rows=len(rows), uniqueExact=len({digest(r['text']) for r in rows}),
        digitClusters=len(clusters), duplicateDigitRows=sum(len(x)-1 for x in clusters.values()),
        conflictingDigitClusters=sum(len({r['label'] for r in x}) > 1 for x in clusters.values()),
        languages=dict(Counter(r.get('language', 'unknown') for r in rows)),
        kinds=dict(Counter(r['filterReview']['kind'] for r in rows)),
        inputForms=dict(Counter(r['filterReview']['inputForm'] for r in rows)),
        sourcePrefixes=dict(Counter(r.get('source', 'unknown').split(':')[0] for r in rows)),
        families=len({r['familyId'] for r in rows if 'familyId' in r}),
        rowsWithFamily=sum('familyId' in r for r in rows),
        urlRows=sum(bool(re.search(r'https?://|www\.', r['text'], re.I)) for r in rows))


def without_vi(weights, languages):
    """Preserve every non-VI weight and batch index, suppress VI supervision only."""
    import torch
    if len(weights) != len(languages):
        raise ValueError('weight membership mismatch')
    return weights * torch.tensor([lang != 'vi' for lang in languages], dtype=weights.dtype)
