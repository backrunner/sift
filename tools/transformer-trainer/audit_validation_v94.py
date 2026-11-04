"""Audit whether evaluation sets can support model decisions. Uses gold rows only.

Reports composition, independence from training, realism and statistical power. Reserved
rows are counted, never scored and never printed. Gold labels are not changed here.
"""
from collections import Counter
import json
import math
from statistics import median

import rebuild_v88 as base
from filter_policy import training_kind
from import_reviewed_public import keys

ROOT = base.ROOT
OUT = ROOT / 'build/signal-validation-audit-v94-20261104'
EVALUATION = ROOT / 'tools/transformer-trainer/experiments/signal-balance-v87-protocol.json'
TRAINING = 'build/signal-contrast-v92-20261104/training.ndjson'
LINK = ('http://', 'https://', 'www.')


def has_link(text): return any(m in text.lower() for m in LINK)


def wilson(correct, total, z=1.96):
    """95% interval for a share; independent rows assumed, so correlated sets are wider still."""
    if not total: return (0., 0.)
    p = correct / total; d = 1 + z * z / total; c = p + z * z / (2 * total)
    m = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total))
    return ((c - m) / d, (c + m) / d)


def family_count(rows):
    """Connected groups by family signature: a floor on how correlated a set is."""
    parent = list(range(len(rows))); owner = {}
    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]; i = parent[i]
        return i
    for i, row in enumerate(rows):
        for key in keys(row['text'], family=True): parent[find(i)] = find(owner.setdefault(key, i))
    return len({find(i) for i in range(len(rows))})


def describe(rows, tokens, train_keys):
    kinds = Counter((r.get('filterReview') or {}).get('kind') or training_kind(r['label']) for r in rows)
    sizes = [tokens(r['text']) for r in rows]
    origin = Counter(str(r.get('source', 'unknown')).split(':')[0] for r in rows)
    return dict(rows=len(rows), kinds=dict(kinds), languages=dict(Counter(r.get('language', '?') for r in rows)),
                labels=len({r['label'] for r in rows}), families=family_count(rows), medianTokens=median(sizes),
                linkShare=round(sum(has_link(r['text']) for r in rows) / len(rows), 3), origin=dict(origin.most_common(8)),
                sharesTrainingFamily=sum(bool(keys(r['text'], family=True) & train_keys) for r in rows))


def main():
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(ROOT / base.SAM[321], local_files_only=True)
    tokens = lambda text: len(tokenizer(text)['input_ids'])
    protocol = json.loads(EVALUATION.read_text())
    sets = {n: base.read(ROOT / c['gold']) for n, c in protocol['cohorts'].items()}
    sets['dev636'] = base.read(ROOT / protocol['development'])
    sets['v92-development'] = base.read(ROOT / 'build/signal-contrast-v92-20261104/development.ndjson')
    sets['real-visible'] = base.read(ROOT / 'build/signal-real-v90-20261103/test-real-visible.ndjson')
    sets['official'] = base.read(ROOT / 'build/signal-real-v90-20261103/test-official.ndjson')
    sets['reserved636-unscored'] = base.read(ROOT / 'build/signal-fine-v81-20261102/reserved.ndjson')
    for n in ('classification', 'promotion', 'billing-card'):
        sets[n] = base.read(ROOT / f'tools/apple-trainer/Evaluation/{n}-regressions.ndjson')
    training = base.read(ROOT / TRAINING); train_keys = {k for r in training for k in keys(r['text'], family=True)}
    report = dict(training=describe(training, tokens, set()), sets={n: describe(r, tokens, train_keys) for n, r in sets.items()})
    conflicts = {}; seen = {}
    for name, rows in sets.items():
        for r in rows:
            for k in keys(r['text']):
                if k.startswith(('exact:', 'near:')): seen.setdefault(k, set()).add(r['label'])
    conflicts = sum(len(v) > 1 for v in seen.values())
    report['labelConflictSignatures'] = conflicts
    OUT.mkdir(exist_ok=True); (OUT / 'composition.json').write_text(json.dumps(report, ensure_ascii=False, indent=1) + '\n')
    return report


if __name__ == '__main__':
    report = main()
    t = report['training']; print('training', t['rows'], t['kinds'], t['languages'], 'tok', t['medianTokens'], 'link', t['linkShare'], t['origin'])
    for n, s in report['sets'].items():
        print(n, s['rows'], 'kinds', s['kinds'], 'lang', s['languages'], 'labels', s['labels'], 'fam', s['families'], 'tok', s['medianTokens'], 'link', s['linkShare'], 'trainfam', s['sharesTrainingFamily'], s['origin'])
    print('conflicts', report['labelConflictSignatures'])
