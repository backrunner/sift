"""Audit correction ownership against the corpus actually learned by a checkpoint."""
from collections import Counter
import hashlib

from replay_distillation import is_reviewed_correction


def text_hash(row):
    return hashlib.sha256(row['text'].encode()).hexdigest()


def audit_reviewed_partition(ownership, training_rows, decisions, prefixes):
    """Allow only explicit content-reviewed changes to a hash-pinned old corpus.

    Relabels and replacements must be hard-target corrections, never teacher
    replay. Missing historical rows require a reviewed deletion or replacement.
    This index records what the checkpoint learned; it does not unlearn it.
    """
    baseline = {r['textSHA256']: r['label'] for r in ownership['rows']}
    if len(baseline) != ownership['count']:
        raise ValueError('duplicate or incomplete baseline ownership index')
    changes = {}
    for item in decisions:
        key = item['textSHA256']
        if key in changes:
            raise ValueError('duplicate review decision')
        if key in baseline and item['oldLabel'] != baseline[key]:
            raise ValueError('review old label differs from checkpoint ownership')
        changes[key] = item
    expected = dict(baseline)
    corrections = set()
    corrected_labels = {}
    replaced = set()
    deleted = 0
    for key, item in changes.items():
        if item['action'] == 'drop':
            if key in expected:
                del expected[key]
                deleted += 1
        else:
            target = item.get('newTextSHA256', key)
            if target != key:
                replaced.add(key)
            if key in expected:
                del expected[key]
                expected[target] = item.get('newLabel', item['oldLabel'])
            corrections.add(target)
            corrected_labels[target] = item.get('newLabel', item['oldLabel'])
    seen = set()
    counts = Counter()
    for row in training_rows:
        key = text_hash(row)
        if key in seen:
            raise ValueError('stage duplicated a training row')
        seen.add(key)
        marked = is_reviewed_correction(row.get('source', ''), prefixes)
        if key in expected and row['label'] != expected[key]:
            raise ValueError('unreviewed historical label change')
        if key in changes and changes[key]['action'] == 'drop':
            raise ValueError('reviewed deletion reintroduced')
        if key in replaced:
            raise ValueError('unrepaired historical body reintroduced')
        if key in corrected_labels and row['label'] != corrected_labels[key]:
            raise ValueError('corrected row differs from reviewed label')
        if key not in expected or key in corrections:
            if not marked:
                raise ValueError('new or corrected row missing hard-target ownership')
            counts['correctionRows'] += 1
        else:
            if marked:
                raise ValueError('unchanged historical row incorrectly marked as correction')
            counts['replayRows'] += 1
    if set(expected) - seen:
        raise ValueError('unreviewed baseline omission or missing replacement')
    return {**dict(counts), 'trainingRows': len(seen),
            'reviewedHistoricalDeletions': deleted, 'baselineRows': len(baseline),
            'reviewedCorrectionsPresent': len(corrections & seen)}


def audit_partition(baseline_rows, training_rows, prefixes, *, allow_historical=False):
    baseline={text_hash(row):row['label'] for row in baseline_rows}
    counts=Counter()
    seen=set()
    for row in training_rows:
        key=text_hash(row)
        if key in seen:
            raise ValueError('stage duplicated a training row')
        seen.add(key)
        historical=key in baseline
        marked=is_reviewed_correction(row.get('source',''),prefixes)
        if historical and baseline[key]!=row['label']:
            raise ValueError('historical label changed without a separately reviewed relabel contract')
        counts['trainingRows']+=1
        counts['historicalRows' if historical else 'newRows']+=1
        counts['correctionRows' if marked else 'replayRows']+=1
        if historical and marked:
            counts['historicalMarkedCorrection']+=1
        if not historical and not marked:
            raise ValueError('new stage row missing from correction ownership')
    if counts['historicalMarkedCorrection'] and not allow_historical:
        raise ValueError('historical rows incorrectly marked as new corrections')
    if not set(baseline).issubset(seen):
        raise ValueError('stage omitted baseline rows')
    return {**dict(counts),'historicalMarkedCorrection':counts['historicalMarkedCorrection'],
        'historicalControlExplicitlyAllowed':allow_historical}
