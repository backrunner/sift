"""Shared safety and selection contract for a frozen action-only experiment."""
import math
from collections import Counter

FLOORS = (.90, .95, .98, .99, .995)
SEEDS = (321, 322)


def validate_design(cases):
    families = set()
    for role, family, label, variants in cases:
        if role not in ('calibration', 'development') or family in families:
            raise ValueError('invalid or split-crossing family')
        families.add(family)
        if len(variants) != 4 or any(len(v) != 3 for v in variants):
            raise ValueError('each family requires four intents in three languages')
        if any(not text.strip() or '://' in text or '{' in text for v in variants for text in v):
            raise ValueError('body-only fully authored text required')
    for role in ('calibration', 'development'):
        if Counter(label for r, _, label, _ in cases if r == role) != {
                'transaction.member': 2, 'transaction.order': 2, 'finance.income': 2}:
            raise ValueError('role coverage changed')


def row_correct(row, decision):
    review = row['filterReview']
    if review['kind'] == 'unresolved' or review['inputForm'] == 'scenario-description':
        return None
    if review['kind'] == 'commercial':
        return decision['engineAction'] in ('promotion', 'junk')
    if review['kind'] == 'harmful':
        return decision['engineAction'] == 'junk'
    return decision['engineAction'] == decision['expectedAction']


def changes(rows, baseline, candidate):
    if not rows or len(rows) != len(baseline) or len(rows) != len(candidate):
        raise ValueError('comparison alignment changed')
    result = dict(recovered=[], introduced=[], newMissToBusiness=[], unscoredChanges=[])
    for i, (row, before, after) in enumerate(zip(rows, baseline, candidate, strict=True)):
        for decision in (before, after):
            if (decision['index'] != i or decision['label'] != row['label']
                    or decision['engineAction'] not in ('none', 'transaction', 'promotion', 'junk')
                    or decision['fallbackReason'] != 'none'):
                raise ValueError('runtime alignment or action contract changed')
        if before['rawPrediction'] != after['rawPrediction'] or before['confidence'] != after['confidence']:
            raise ValueError('action-only comparison changed model output')
        old, new = row_correct(row, before), row_correct(row, after)
        if old is False and new is True: result['recovered'].append(i)
        if old is True and new is False: result['introduced'].append(i)
        if old is None and before['engineAction'] != after['engineAction']:
            result['unscoredChanges'].append(i)
        if (old is not None and row['filterReview']['kind'] in ('commercial', 'harmful')
                and before['engineAction'] != 'transaction' and after['engineAction'] == 'transaction'):
            result['newMissToBusiness'].append(i)
    return result


def safe(comparison):
    return not comparison['introduced'] and not comparison['newMissToBusiness']


def select_floor(records):
    """Only fresh calibration may enter here; no legacy/development score keys."""
    if len(records) != len(FLOORS) or {r['floor'] for r in records} != set(FLOORS):
        raise ValueError('incomplete or duplicate fixed grid')
    for r in records:
        if set(r) != {'floor', 'calibration'} or set(r['calibration']) != {str(s) for s in SEEDS}:
            raise ValueError('selection requires calibration for both fixed seeds only')
        for arm in r['calibration'].values():
            if set(arm) != {'actionCorrect', 'scored', 'comparison'}:
                raise ValueError('unexpected selection metric')
            if not 0 <= arm['actionCorrect'] <= arm['scored'] or arm['scored'] != 72:
                raise ValueError('invalid calibration count')
    eligible = [r for r in records if all(safe(a['comparison']) for a in r['calibration'].values())
                and sum(len(a['comparison']['recovered']) for a in r['calibration'].values()) > 0]
    if not eligible:
        return None
    # Equal-sized, balanced families/languages. Protect the weaker seed, then
    # improve the pair; highest mass wins exact score ties for conservatism.
    return max(eligible, key=lambda r: (
        min(a['actionCorrect'] for a in r['calibration'].values()),
        sum(a['actionCorrect'] for a in r['calibration'].values()), r['floor']))['floor']


def qualify(fresh, historical):
    """A one-shot veto after calibration, never a reason to pick another floor."""
    return all(safe(r['comparison']) for r in historical + fresh) and all(
        r['policy']['policyActionAccuracy'] >= .90
        and r['policy']['harmfulRecall'] >= .90
        and r['policy']['normalToJunk'] == 0
        and r['policy']['normalToPromotion'] == 0 for r in fresh)
