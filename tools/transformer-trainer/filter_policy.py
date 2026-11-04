"""Reviewed action tolerance, without merging taxonomy IDs or weakening harm labels.

Commercial targets supervise the probability of the accepted label *set*.
They do not invent a 50/50 soft label or distill an obsolete junk/promo split.
Ordinary and harmful rows retain the existing supervised/KD objective.
"""
from collections import Counter
import hashlib

PROMOTION_LABELS = ('promotion', 'carrier.promotion')
COMMERCIAL_LABELS = ('spam', 'promotion', 'carrier.promotion')
KINDS = ('normal', 'commercial', 'harmful', 'unresolved')


def identity(text):
    return hashlib.sha256(text.encode()).hexdigest()


def training_kind(label):
    if label in PROMOTION_LABELS:
        return 'commercial'
    return 'harmful' if label == 'spam' else 'normal'


def allowed_labels(label, kind):
    if kind == 'commercial':
        return list(COMMERCIAL_LABELS)
    if kind == 'harmful':
        return ['spam']
    if kind == 'normal':
        return [label]
    return []


def validate_targets(rows, spec):
    if spec.get('kind') != 'reviewed-filter-targets' or spec.get('schemaVersion') != 1:
        raise ValueError('unsupported filter target policy')
    entries = spec['entries']
    if len(rows) != len(entries) or set(entries) != {identity(r['text']) for r in rows}:
        raise ValueError('filter target membership mismatch')
    counts = Counter()
    for row in rows:
        entry = entries[identity(row['text'])]
        kind = training_kind(row['label'])
        if (entry['label'] != row['label'] or entry['source'] != row['source']
                or entry['language'] != row['language'] or entry['kind'] != kind
                or entry['allowedLabels'] != allowed_labels(row['label'], kind)):
            raise ValueError('filter target label/source/policy drift')
        if not entry.get('reviewBasis'):
            raise ValueError('filter target lacks review basis')
        counts[kind] += 1
    return dict(counts)


def marginal_commercial_loss(logits, label_to_id):
    import torch
    ids = [label_to_id[label] for label in COMMERCIAL_LABELS]
    return torch.logsumexp(logits, dim=-1) - torch.logsumexp(logits[:, ids], dim=-1)


def install_loss(label_to_id):
    """The same functions are used by ordinary, SAM second-pass and gradient probes."""
    import torch
    import hard_label_loss
    import replay_distillation
    original_hard = hard_label_loss.supervised_loss
    original_replay = replay_distillation.replay_distillation_loss
    for label in COMMERCIAL_LABELS:
        if label not in label_to_id:
            raise ValueError('filter policy requires the unchanged taxonomy')
    promo_ids = [label_to_id[label] for label in PROMOTION_LABELS]

    def commercial(labels):
        return (labels == promo_ids[0]) | (labels == promo_ids[1])

    def hard(logits, labels, label_smoothing=0., focal_gamma=0.):
        if label_smoothing or focal_gamma:
            raise ValueError('filter policy does not combine smoothing or focal loss')
        ordinary = original_hard(logits, labels)
        return torch.where(commercial(labels), marginal_commercial_loss(logits, label_to_id), ordinary)

    def replay(student_logits, teacher_logits, labels, correction_mask, *args, **kwargs):
        ordinary = original_replay(student_logits, teacher_logits, labels, correction_mask, *args, **kwargs)
        # No fine-label KD or (1-alpha) CE attenuation on tolerant commercial rows.
        # Strict rows are bit-for-bit the previous correct-teacher objective.
        return torch.where(commercial(labels), marginal_commercial_loss(student_logits, label_to_id), ordinary)

    hard_label_loss.supervised_loss = hard
    replay_distillation.replay_distillation_loss = replay

    def restore():
        hard_label_loss.supervised_loss = original_hard
        replay_distillation.replay_distillation_loss = original_replay

    return restore


def score_policy(rows, runtime, actions, *, include_scenarios=False):
    """Report fixed-policy metrics and explicit coverage; no prediction-based exclusion."""
    if len(rows) != len(runtime):
        raise ValueError('policy prediction membership mismatch')
    counts = Counter()
    errors = []
    for index, (row, pred) in enumerate(zip(rows, runtime)):
        if row['text'] != pred['text'] or row['label'] != pred['label']:
            raise ValueError('policy prediction alignment drift')
        review = row['filterReview']
        kind = review['kind']
        action = pred['engineAction']
        if kind not in KINDS or action not in ('none', 'transaction', 'promotion', 'junk'):
            raise ValueError('unsupported policy class/action')
        counts['total'] += 1
        if kind == 'unresolved':
            counts['unresolved'] += 1
            counts['unresolvedToJunk'] += action == 'junk'
            continue
        if review['inputForm'] == 'scenario-description' and not include_scenarios:
            counts['scenarioDescriptions'] += 1
            continue
        counts['scored'] += 1
        counts[kind] += 1
        expected = actions[row['label']]
        if kind == 'commercial':
            correct = action in ('promotion', 'junk')
            counts['commercialCaught'] += correct
            counts['commercialToJunk'] += action == 'junk'
        elif kind == 'harmful':
            correct = action == 'junk'
            counts['harmfulCaught'] += correct
            counts['harmfulToPromotion'] += action == 'promotion'
            counts['harmfulToNormal'] += action in ('none', 'transaction')
        else:
            correct = action == expected
            counts['normalToJunk'] += action == 'junk'
            counts['normalToPromotion'] += action == 'promotion'
            counts['normalFineCorrect'] += pred['prediction'] == row['label']
        counts['actionCorrect'] += correct
        if not correct:
            errors.append({'index': index, 'oldIndex': row.get('oldIndex'), 'kind': kind,
                           'label': row['label'], 'action': action, 'textSHA256': identity(row['text'])})
    # Stable keys, including true zeros, for gates and reports.
    for key in ('normalToJunk', 'normalToPromotion', 'commercialToJunk', 'harmfulToPromotion',
                'harmfulToNormal', 'unresolved', 'unresolvedToJunk', 'scenarioDescriptions',
                'normal', 'commercial', 'harmful', 'harmfulCaught', 'commercialCaught',
                'normalFineCorrect', 'actionCorrect', 'scored'):
        counts[key] += 0
    result = dict(counts)
    result['normalToFiltered'] = counts['normalToJunk'] + counts['normalToPromotion']
    for name, numerator, denominator in (
        ('policyActionAccuracy', counts['actionCorrect'], counts['scored']),
        ('harmfulRecall', counts['harmfulCaught'], counts['harmful']),
        ('commercialRecall', counts['commercialCaught'], counts['commercial']),
        ('normalFineAccuracy', counts['normalFineCorrect'], counts['normal']),
        ('normalProtection', counts['normal'] - result['normalToFiltered'], counts['normal']),
    ):
        result[name] = numerator / denominator if denominator else None
    result['errors'] = errors
    return result
