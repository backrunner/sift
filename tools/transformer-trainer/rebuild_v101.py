"""New training process: styled training rows, and epochs chosen by serious errors first.

Arms: process-v101 uses the existing pool, and process-data-v101 adds the composed zh, ja and realistic
rows. Both are judged once on a sealed test written before they trained. Cannot install a model.

Stages run in order: smoke, seal, train --arm A --seed S, select.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import random
import tempfile

import evaluate_signal_v100 as evaluation
import rebuild_v88 as base
import rebuild_v89 as v89
import rebuild_v94 as v94
from sms_style_v101 import style

ROOT = base.ROOT
NAME = 'signal-rebuild-v101'
OUT = ROOT / 'build/signal-rebuild-v101-20261104'
STORAGE = Path.home() / 'Library/Caches/SiftTraining' / OUT.name
PROTOCOL = ROOT / 'tools/transformer-trainer/experiments' / (NAME + '-protocol.json')
DATA = 'build/signal-realistic-v101-20261104'
COMBINED = 'build/signal-rebuild-v101-20261104/training-data.ndjson'
ARMS = {'process-v101': dict(init='sam', layers=12, lr=1e-5, training=v94.HOSTS, epochs=23),
        'process-data-v101': dict(init='sam', layers=12, lr=1e-5, training=COMBINED, epochs=21)}
THREADS = 3
SELECTION = {**base.SELECTION, 'dev67': f'{DATA}/development.ndjson'}


def rank_key(metric, epoch):
    """Serious errors, then all errors, then fine labels, then the earlier epoch."""
    return (metric['serious'], sum(metric['errors'].values()), -metric['fine']['correct'], epoch)


class StyledTokenizer:
    """Style only training batches. Evaluation pads to max_length and always sees the plain text."""
    def __init__(self, tokenizer, lookup, seed):
        self.tokenizer = tokenizer; self.lookup = lookup; self.rng = random.Random(seed)

    def __call__(self, texts, **kwargs):
        if kwargs.get('padding') == 'longest':
            texts = [style(t, *self.lookup[t], self.rng) for t in texts]
        return self.tokenizer(texts, **kwargs)

    def __getattr__(self, name): return getattr(self.tokenizer, name)


def combine():
    OUT.mkdir(exist_ok=True); target = ROOT / COMBINED
    if not target.exists():
        rows = base.read(ROOT / v94.HOSTS) + base.read(ROOT / 'build/signal-cjk-v96-20261104/new-training.ndjson') + base.read(ROOT / DATA / 'new-training.ndjson')
        base.dump(target, rows)


def install(arm, seed):
    import transformers
    spec = ARMS[arm]; base.ARMS[arm] = {k: spec[k] for k in ('init', 'layers', 'lr')}
    base.STORAGE = STORAGE; base.PROTOCOL = PROTOCOL; base.COMMON['threads'] = THREADS; base.SELECTION = SELECTION
    rows = base.read(ROOT / spec['training']); weights = v89.weights_for(rows, v89.cell_weights())
    base.training_inputs = lambda: (rows, weights)
    lookup = {r['text']: (r['label'], r['language']) for r in rows}; loader = transformers.AutoTokenizer.from_pretrained
    transformers.AutoTokenizer.from_pretrained = lambda *a, **k: StyledTokenizer(loader(*a, **k), lookup, seed)
    return rows, loader


def check():
    protocol = json.loads(PROTOCOL.read_text())
    for path, digest in protocol['filesSHA256'].items():
        if base.sha(ROOT / path) != digest: raise ValueError('sealed dependency drift: ' + path)
    return protocol


def smoke():
    import transformers
    combine()
    for arm in ARMS:
        rows, loader = install(arm, base.SEEDS[0])
        with tempfile.TemporaryDirectory() as folder:
            print('smoke', arm, len(rows), base.fit(arm, base.SEEDS[0], Path(folder), 1, max_updates=2, evaluate=False), flush=True)
        transformers.AutoTokenizer.from_pretrained = loader


def seal():
    if PROTOCOL.exists(): raise ValueError('protocol is sealed; use a new version')
    combine(); me = Path(__file__).resolve(); budgets = {}
    others = {p: base.read(ROOT / p) for p in [*base.SELECTION.values(), base.HISTORY, *base.ISOLATION, f'{DATA}/development.ndjson', f'{DATA}/test.ndjson']}
    for arm, spec in ARMS.items():
        rows = base.read(ROOT / spec['training']); leaks = base.overlap(rows, others)
        if any(leaks.values()): raise ValueError(f'{arm} holdout overlap {leaks}')
        budgets[arm] = dict(rows=len(rows), updates=base.window_plan(len(rows), 32, 4)['updatesPerEpoch'] * spec['epochs'])
    files = [v94.HOSTS, COMBINED, f'{DATA}/test.ndjson', f'{DATA}/development.ndjson', f'{DATA}/new-training.ndjson', base.RUNTIME, *base.SELECTION.values(),
             *[str(me.with_name(n).relative_to(ROOT)) for n in ('sms_style_v101.py', 'evaluate_signal_v100.py', 'author_realistic_test_v101.py', 'author_realistic_train_v101.py', 'prepare_realistic_v101.py', 'rebuild_v88.py', 'rebuild_v89.py', 'rebuild_v94.py')],
             str(me.with_name('tests').joinpath('test_rebuild_v101.py').relative_to(ROOT)), str(me.relative_to(ROOT)),
             'tools/transformer-trainer/experiments/signal-gold-review-v100.json']
    PROTOCOL.write_text(json.dumps(dict(name=NAME, createdUTC=datetime.now(timezone.utc).isoformat(), arms=ARMS, budgets=budgets, common=base.COMMON | {'threads': THREADS}, seeds=base.SEEDS,
        process='Fresh SMS styling on every training pass: digits, signatures, service tails, opt-outs and links at the same rate for every label. Evaluation text is never styled.',
        selection='Spent old493+dev636 plus 67 new development rows, ranked by serious errors, all errors, fine labels, then earlier epoch. Bare encoder decisions.',
        test=dict(set='realistic287', rows=287, rule='Scored once after epochs and gates freeze. Compare each arm with free-v92 gate 36 per seed using evaluate_signal_v100. An arm improves if both seeds have fewer or equal serious errors and fewer or equal total errors, and neither seed interval on serious errors is wholly against it. Fixed suites are floors: classification strict within 2, promotion tolerant at least 149, billing equal.'),
        comparators=['free-v92 gate 36', 'SAM + v79'],
        limits=['The test and training share one author, who wrote both on the same day. Same-author bias remains, though scenarios differ and overlap checks passed.', 'Test rows are synthetic, not received messages.', 'Reserved 624 stays for a single later fine-label comparison.'],
        reservedScored=False, automaticReplacement=False, releaseEligible=False, filesSHA256={f: base.sha(ROOT / f) for f in files}), ensure_ascii=False, indent=2) + '\n')
    print('sealed', budgets, flush=True)


def train(arm, seed):
    check(); install(arm, seed); target = STORAGE / f'{arm}-{seed}'
    if target.exists(): raise ValueError('trial output exists: ' + str(target))
    base.fit(arm, seed, target, ARMS[arm]['epochs'])


def select():
    check(); actions = evaluation.actions(); cohorts = {k: base.read(ROOT / p) for k, p in SELECTION.items()}; results = {}
    joined = [r for rows in cohorts.values() for r in evaluation.apply_overlay(rows, json.loads(evaluation.OVERLAY.read_text()))]
    for arm, spec in ARMS.items():
        for seed in base.SEEDS:
            trial = STORAGE / f'{arm}-{seed}'; records = []
            for epoch in range(spec['epochs'] + 1):
                decisions = []
                for name, rows in cohorts.items():
                    prefix = trial / f'epoch-{epoch:03d}-{name}'
                    decisions += base.replay(rows, base.read(f'{prefix}-predictions.ndjson'), prefix)[0]
                metric = evaluation.report(joined, decisions, actions); records.append((rank_key(metric, epoch), epoch, metric))
            key, epoch, metric = min(records, key=lambda r: r[0])
            results[f'{arm}:{seed}'] = dict(selectedEpoch=epoch, serious=metric['serious'], errors=metric['errors'], fine=metric['fine'], curve=[dict(epoch=e, serious=m['serious'], fine=m['fine']['correct']) for _, e, m in records])
            print(arm, seed, 'epoch', epoch, 'serious', metric['serious'], 'fine', metric['fine']['correct'], flush=True)
    (OUT / 'selection.json').write_text(json.dumps(dict(testUsed=False, results=results), indent=1) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('smoke', 'seal', 'train', 'select'))
    parser.add_argument('--arm', choices=tuple(ARMS)); parser.add_argument('--seed', type=int, choices=base.SEEDS)
    a = parser.parse_args()
    if a.stage == 'train': train(a.arm, a.seed)
    else: globals()[a.stage]()
