"""Training-only Vietnamese exposure reduction, fitted from corpus counts.

Keep all reviewed bodies and all other languages unchanged. Match Vietnamese
intent proportions to Japanese by downweighting only; never infer prevalence.
"""
from collections import Counter
import hashlib
import json

from filter_policy import identity, training_kind


def build_spec(rows, training_sha):
    counts = Counter((r['language'], training_kind(r['label'])) for r in rows)
    kinds = ('normal', 'commercial', 'harmful')
    if any(counts[lang, kind] == 0 for lang in ('ja', 'vi') for kind in kinds):
        raise ValueError('reference and reduced languages require all three intents')
    # Largest retained VI mass with the JA proportions and no upweighting.
    scale = min(counts['vi', k] / counts['ja', k] for k in kinds)
    group_weights = {k: scale * counts['ja', k] / counts['vi', k] for k in kinds}
    if any(not .1 <= w <= 1. + 1e-12 for w in group_weights.values()):
        raise ValueError('reference match exceeds preregistered downweight bounds')
    entries = {}
    for r in rows:
        key = identity(r['text'])
        if key in entries:
            raise ValueError('duplicate training identity')
        entries[key] = {k: r[k] for k in ('label', 'language', 'source')}
        entries[key]['weight'] = group_weights[training_kind(r['label'])] if r['language'] == 'vi' else 1.
    vi_mass = sum(counts['vi', k] * group_weights[k] for k in kinds)
    ja_total = sum(counts['ja', k] for k in kinds)
    total = sum(e['weight'] for e in entries.values())
    return {'schemaVersion': 1, 'kind': 'language-intent-downweight-only',
        'trainingSHA256': training_sha, 'entries': entries,
        'referenceLanguage': 'ja', 'reducedLanguage': 'vi',
        'rawCounts': {l: {k: counts[l, k] for k in kinds} for l in sorted({r['language'] for r in rows})},
        'vietnameseWeights': group_weights,
        'japaneseIntentFractions': {k: counts['ja', k] / ja_total for k in kinds},
        'vietnameseWeightedIntentFractions': {k: counts['vi', k] * group_weights[k] / vi_mass for k in kinds},
        'vietnameseRawRows': sum(counts['vi', k] for k in kinds),
        'vietnameseWeightMass': vi_mass, 'allTrainingWeightMass': total,
        'kishEffectiveSampleSize': total**2 / sum(e['weight']**2 for e in entries.values()),
        'rowsDeleted': 0, 'oversampling': False, 'newTrainingRows': 0,
        'bounds': [.1, 1.], 'otherLanguagesUnchanged': True,
        'rule': 'VI effective intent proportions match raw Japanese normal/commercial/harmful proportions. Largest non-upweighting scale, bounded0.1..1. All zh/en/ja weights remain1. Corpus bodies, gold, sampling order and evaluation remain fixed.',
        'interpretation': 'Objective mass, not an estimate of deployment prevalence or a count of independent samples. Valid fraud diversity remains in every epoch.'}


def validate(rows, spec):
    expected = build_spec(rows, spec['trainingSHA256'])
    if spec != expected:
        raise ValueError('language weighting differs from the training-only rule or identities')


def install(path, enabled):
    # This adapter also disables training lookup inside ordinary evaluation.
    from reviewed_weights_v46r1 import install as install_reviewed
    return install_reviewed(path, enabled)


def install_language_probes(rows):
    """Augment the existing fixed-parameter probes, without optimizer updates."""
    import torch
    from torch.utils.data import DataLoader, Subset
    import gradient_diagnostics as diagnostics
    original = diagnostics.full_gradient_probe
    groups = {l: [i for i, r in enumerate(rows) if r['language'] == l]
        for l in sorted({r['language'] for r in rows})}

    def probe(model, loader, objective, device, **kwargs):
        if (len(loader.dataset) != len(rows)
                or not hasattr(loader.dataset, 'rows')
                or [(r['text'], r['label']) for r in loader.dataset.rows]
                   != [(r['text'], r['label']) for r in rows]):
            raise ValueError('per-language probe requires full registered training order')
        result = original(model, loader, objective, device, **kwargs)
        result['byLanguageDataObjective'] = {}
        for lang, indices in groups.items():
            subset = DataLoader(Subset(loader.dataset, indices), batch_size=loader.batch_size,
                shuffle=False, collate_fn=loader.collate_fn,
                generator=torch.Generator().manual_seed(0))
            # Anchor is a model-wide penalty, not four separate language penalties.
            m = original(model, subset, objective, device)
            result['byLanguageDataObjective'][lang] = m
        return result
    diagnostics.full_gradient_probe = probe

    def restore():
        diagnostics.full_gradient_probe = original
    return restore


def verify_study(protocol_path):
    from approved_signal import ROOT
    protocol = json.loads(protocol_path.read_text())
    for name, digest in protocol['filesSHA256'].items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
            raise ValueError('language study dependency drift: ' + name)
    return protocol


def policy_metrics(rows, joined, actions):
    from filter_policy import score_policy
    result = {'policy': score_policy(rows, joined, actions), 'byLanguage': {}}
    for lang in sorted({r['language'] for r in rows}):
        indices = [i for i, r in enumerate(rows) if r['language'] == lang]
        result['byLanguage'][lang] = score_policy([rows[i] for i in indices], [joined[i] for i in indices], actions)
    result['macroLanguageActionAccuracy'] = sum(m['policyActionAccuracy'] for m in result['byLanguage'].values()) / len(result['byLanguage'])
    return result


def eligible(record, baseline):
    m, b = record['policy'], baseline['policy']
    aggregate = (m['normalToJunk'] <= min(2, b['normalToJunk'])
        and m['normalToPromotion'] <= b['normalToPromotion']
        and m['harmfulRecall'] is not None and m['harmfulRecall'] >= .90
        and m['actionCorrect'] >= b['actionCorrect'] - 2
        and m['normalFineCorrect'] >= b['normalFineCorrect'] - 2)
    if set(record['byLanguage']) != set(baseline['byLanguage']):
        raise ValueError('language cohort drift')
    return aggregate and all(m['normalToJunk'] <= baseline['byLanguage'][lang]['normalToJunk']
        and m['normalToPromotion'] <= baseline['byLanguage'][lang]['normalToPromotion']
        and m['harmfulCaught'] >= baseline['byLanguage'][lang]['harmfulCaught']
        for lang, m in record['byLanguage'].items())


def selection_key(record, baseline):
    m = record['policy']
    return (int(eligible(record, baseline)), -m['normalToFiltered'], -m['normalToJunk'],
        m['harmfulCaught'], record['macroLanguageActionAccuracy'], m['normalFineCorrect'], -record['epoch'])


def select(records):
    if sum(r['epoch'] == 0 for r in records) != 1 or len({r['epoch'] for r in records}) != len(records):
        raise ValueError('unique epoch zero and distinct epochs required')
    base = next(r for r in records if r['epoch'] == 0)
    diagnostic = max(records, key=lambda r: selection_key(r, base))
    accepted = [r for r in records if eligible(r, base)]
    return (max(accepted, key=lambda r: selection_key(r, base)) if accepted else base), diagnostic, bool(accepted)
