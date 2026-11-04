"""Reviewed family-preserving views, bounded sampling and paired consistency.

Sampling changes the expected language/action mixture, not each fine label's
total mass. New translations are views of existing roots, never extra roots.
The full-gradient loader integrates every accepted view rather than probing
only the randomly/rotationally selected view used in a training epoch.
"""
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def action(label):
    return ('junk' if label == 'spam' else 'none' if label == '__sift_abstain__'
            else 'promotion' if label in ('promotion', 'carrier.promotion') else 'transaction')


def balanced_weights(rows):
    languages = Counter(r['language'] for r in rows)
    actions = Counter(action(r['label']) for r in rows)
    cells = Counter((r['language'], action(r['label'])) for r in rows)
    values = [min(2., max(.5, math.sqrt((actions[action(r['label'])] / len(rows)) /
                  (cells[r['language'], action(r['label'])] / languages[r['language']])))) for r in rows]
    # Preserve the original fine-label prior exactly in expectation. This is
    # not an attempt to make the natural deployment population uniform.
    totals = defaultdict(float); counts = Counter(r['label'] for r in rows)
    for r, w in zip(rows, values): totals[r['label']] += w
    values = [w * counts[r['label']] / totals[r['label']] for r, w in zip(rows, values)]
    return values


def load_spec(path, rows, tokenizer=None):
    from import_reviewed_public import keys
    from prepare_approved_signal import quality_reason
    from retired_samples import RetiredSamples
    spec = json.loads(Path(path).read_text())
    if spec.get('schemaVersion') != 1 or spec.get('maxLength') != 96:
        raise ValueError('unsupported multilingual-view contract')
    ordered = [digest(r['text']) for r in rows]
    if spec['rootTextSHA256'] != ordered:
        raise ValueError('multilingual roots changed or reordered')
    roots = {digest(r['text']): r for r in rows}
    protected = set(spec['protectedSignatureSHA256'])
    retired = RetiredSamples(); views = {}; seen = {}; owners = {}
    for group in spec['groups']:
        if group['groupID'] in seen: raise ValueError('duplicate translation group')
        seen[group['groupID']] = True
        if not group['parents'] or not group['translations']:
            raise ValueError('empty translation family')
        for parent in group['parents']:
            if parent not in roots or parent in owners: raise ValueError('missing or multiple parent ownership')
            if roots[parent]['label'] != group['label']: raise ValueError('cross-label view group')
            owners[parent] = group['groupID']
        members = [roots[p] for p in group['parents']] + group['translations']
        text_hashes = [digest(r['text']) for r in members]
        if len(text_hashes) != len(set(text_hashes)): raise ValueError('duplicate view in family')
        for r in group['translations']:
            if r['label'] != group['label'] or not r.get('reviewReason') or r.get('review') != 'accepted':
                raise ValueError('unreviewed or relabeled translation')
            if quality_reason(r) or retired.reason(r): raise ValueError('malformed or retired translation')
            signatures = {digest(k) for k in keys(r['text'], family=True)}
            if signatures & protected: raise ValueError('translation overlaps protected evaluation')
            if tokenizer is not None:
                ids = tokenizer(r['text'])['input_ids']
                if len(ids) != r['tokenCount'] or len(ids) > 96: raise ValueError('view token evidence drift')
            if group['label'] == 'spam':
                spans = r.get('supportSpans', [])
                if not spans or any(not 0 <= a < b <= len(r['text']) for a, b in spans):
                    raise ValueError('junk view lacks reviewed visible evidence')
        for parent in group['parents']:
            views[parent] = [r['text'] for r in members if digest(r['text']) != parent]
    # Block translations that duplicate a root outside their explicit family,
    # or belong to two families, even when both families have the same label.
    signature_owners = {}
    for parent, row in roots.items():
        owner = owners.get(parent, parent)
        for k in keys(row['text'], family=True): signature_owners[digest(k)] = owner
    for group in spec['groups']:
        for row in group['translations']:
            for k in keys(row['text'], family=True):
                key = digest(k)
                if key in signature_owners and signature_owners[key] != group['groupID']:
                    raise ValueError('translation crosses training families')
                signature_owners[key] = group['groupID']
    return spec, views


class PairedRows:
    def __init__(self, base, rows, views, mode, seed):
        self.base, self.rows, self.views = base, rows, views
        self.mode, self.seed, self.epoch = mode, seed, 0

    def __len__(self): return len(self.base)

    def __getitem__(self, index):
        item = self.base[index]; text = self.rows[index]['text']
        variants = self.views.get(digest(text), []) if self.mode in ('translated', 'consistent') else []
        offset = (int(digest(text)[:8], 16) + self.seed + self.epoch) % len(variants) if variants else 0
        return {**item, 'view_text': variants[offset] if variants else text, 'probe_weight': 1.}


class ExpectedPairs:
    def __init__(self, dataset, weights):
        self.dataset = dataset; self.entries = []
        for i, (row, weight) in enumerate(zip(dataset.rows, weights)):
            variants = dataset.views.get(digest(row['text']), []) if dataset.mode in ('translated', 'consistent') else []
            variants = variants or [row['text']]
            self.entries.extend((i, text, weight / len(variants)) for text in variants)

    def __len__(self): return len(self.entries)

    def __getitem__(self, index):
        i, text, weight = self.entries[index]
        return {**self.dataset.base[i], 'view_text': text, 'probe_weight': weight}


def paired_collate(base_collate, tokenizer, max_length):
    def collate(batch):
        import torch
        result = base_collate(batch)
        encoded = tokenizer([r['view_text'] for r in batch], truncation=True, padding='max_length',
                            max_length=max_length, return_tensors='pt')
        result.update({'view_' + k: v for k, v in encoded.items()})
        result['pair_mask'] = torch.tensor([r['text'] != r['view_text'] for r in batch], dtype=torch.bool)
        result['loss_weights'] *= torch.tensor([r['probe_weight'] for r in batch])
        return result
    return collate


def pop_view_batch(batch):
    if 'view_input_ids' not in batch: return None, None
    view = {k[5:]: batch.pop(k) for k in list(batch) if k.startswith('view_')}
    return view, batch.pop('pair_mask')


def paired_loss(original_logits, translated_logits, original_teacher, translated_teacher,
                labels, correction_mask, pair_mask, arguments):
    import torch
    import torch.nn.functional as F
    from replay_distillation import replay_distillation_loss
    kwargs = dict(alpha=arguments.replay_alpha, temperature=arguments.replay_temperature,
        label_smoothing=arguments.label_smoothing, only_correct_teacher=True,
        agreement_all_rows=True, hard_label_mode=arguments.replay_hard_label_mode)
    first = replay_distillation_loss(original_logits, original_teacher, labels, correction_mask, **kwargs)
    second = replay_distillation_loss(translated_logits, translated_teacher, labels, correction_mask, **kwargs)
    # Each original family retains one unit of supervised mass, irrespective
    # of how many translations were accepted for it.
    supervised = .5 * (first + second)
    logp, logq = F.log_softmax(original_logits.float(), -1), F.log_softmax(translated_logits.float(), -1)
    logm = torch.logaddexp(logp, logq) - math.log(2.)
    js = .5 * ((logp.exp() * (logp - logm)).sum(-1) + (logq.exp() * (logq - logm)).sum(-1))
    valid = pair_mask & (original_teacher.detach().argmax(-1) == labels)
    coefficient = arguments.translation_consistency_weight if arguments.multilingual_mode == 'consistent' else 0.
    return supervised + coefficient * torch.where(valid, js, 0.)


def make_plan(dataset, rows, collate, tokenizer, arguments, generator):
    import torch
    from torch.utils.data import WeightedRandomSampler
    spec, views = load_spec(arguments.multilingual_view_spec, rows, tokenizer)
    weights = [1.] * len(rows) if arguments.multilingual_mode == 'uniform' else balanced_weights(rows)
    paired = PairedRows(dataset, rows, views, arguments.multilingual_mode, arguments.seed)
    sampler = WeightedRandomSampler(torch.tensor(weights, dtype=torch.double), len(rows), replacement=True, generator=generator)
    expected = defaultdict(float)
    for row, weight in zip(rows, weights): expected[row['language'] + ':' + action(row['label'])] += weight
    language_by_text = {r['text']: r['language'] for r in rows}
    for group in spec['groups']:
        language_by_text.update({r['text']: r['language'] for r in group['translations']})
    rendered = defaultdict(float)
    for row, weight in zip(rows, weights):
        variants = views.get(digest(row['text']), []) if arguments.multilingual_mode in ('translated', 'consistent') else []
        variants = variants or [row['text']]
        rendered[row['language'] + ':' + action(row['label'])] += .5 * weight
        for variant in variants:
            rendered[language_by_text[variant] + ':' + action(row['label'])] += .5 * weight / len(variants)
    report = {'mode': arguments.multilingual_mode, 'specSHA256': hashlib.sha256(Path(arguments.multilingual_view_spec).read_bytes()).hexdigest(),
        'roots': len(rows), 'pairedRoots': len(views), 'groups': len(spec['groups']),
        'newViews': sum(len(g['translations']) for g in spec['groups']), 'samplingReplacement': True,
        'minimumSamplingWeight': min(weights), 'maximumSamplingWeight': max(weights),
        'expectedLanguageActionMass': dict(expected), 'fineLabelMassPreservedInExpectation': True,
        'expectedRenderedLanguageActionMass': dict(rendered),
        'viewMixture': [.5, .5], 'consistencyWeight': arguments.translation_consistency_weight if arguments.multilingual_mode == 'consistent' else 0.,
        'probe': 'Exact expected data objective over all roots and all accepted views; weighted by sampling probability.'}
    return paired, paired_collate(collate, tokenizer, arguments.max_length), sampler, ExpectedPairs(paired, weights), report
