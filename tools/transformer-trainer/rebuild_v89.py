"""Separate recipe from data in the v88 warm-free result.

V88 warm-free trained on v85, which holds 552 rows written after SAM. V89 repeats
that recipe on SAM's generation (v52) and on v85 plus ledger-admitted rows, with
matched update budgets and the v85 per-cell row weights. It reuses the v88 trainer
and frozen runtime, never scores reserved rows, and cannot install a model.

Stages run in order: smoke, seal, train --arm A --seed S, select, verdict.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
from pathlib import Path
from statistics import median
import tempfile

import rebuild_v88 as base
from evaluation_audit_v86 import action_map, score

ROOT = base.ROOT
NAME = 'signal-rebuild-v89'
OUT = ROOT / 'build/signal-rebuild-v89-20261103'
STORAGE = Path.home() / 'Library/Caches/SiftTraining' / OUT.name
PROTOCOL = ROOT / 'tools/transformer-trainer/experiments' / (NAME + '-protocol.json')
V88_OUT = ROOT / 'build/signal-rebuild-v88-20261103'
V52 = 'tools/apple-trainer/Training/signal-language-quality-v52.ndjson'
ADMITTED = 'build/signal-admission-v89-20261103/training.ndjson'
ARMS = {'free-v52': dict(init='sam', layers=12, lr=1e-5, training=V52, epochs=28),
        'free-v89': dict(init='sam', layers=12, lr=1e-5, training=ADMITTED, epochs=19)}
THREADS = 4
MAX_NORMAL_JUNK_INCREASE = 2


def cell_weights():
    rows = base.read(ROOT / base.TRAINING); legacy = json.loads((ROOT / base.WEIGHTS).read_text())['legacy']
    cells = {}
    for row, weight in zip(rows, legacy, strict=True):
        cell = (row['label'], row['language'])
        if cells.setdefault(cell, weight) != weight: raise ValueError(f'cell weight is not constant: {cell}')
    return cells


def weights_for(rows, cells):
    # V52 keeps a Vietnamese cell that v85 dropped. Core-language gaps stay errors.
    missing = {(r['label'], r['language']) for r in rows} - set(cells)
    if any(language != 'vi' for _, language in missing):
        raise ValueError(f'no v85 weight for cells: {sorted(missing)}')
    fallback = median(w for (_, language), w in cells.items() if language == 'vi') if missing else None
    return [cells.get((r['label'], r['language']), fallback) for r in rows]


def install(arm):
    """Point the v88 trainer at this arm without changing its training loop."""
    spec = ARMS[arm]; base.ARMS[arm] = {k: spec[k] for k in ('init', 'layers', 'lr')}
    base.STORAGE = STORAGE; base.PROTOCOL = PROTOCOL; base.COMMON['threads'] = THREADS
    rows = base.read(ROOT / spec['training']); weights = weights_for(rows, cell_weights())
    base.training_inputs = lambda: (rows, weights)
    return rows


def data_signal(candidate, reference):
    """Both seeds must pass: admitted data helps without costing safety."""
    a, b = candidate['selection'], reference['selection']
    low_a, low_b = candidate['history']['lowSimilarity'], reference['history']['lowSimilarity']
    return bool(a['fineCorrect'] >= b['fineCorrect'] + .005 * b['actionScored']
                and a['policyActionCorrect'] >= b['policyActionCorrect']
                and a['normalToJunk'] <= b['normalToJunk'] + MAX_NORMAL_JUNK_INCREASE
                and low_a['policyActionCorrect'] / low_a['actionScored'] >= low_b['policyActionCorrect'] / low_b['actionScored'] - .005)


def check():
    protocol = json.loads(PROTOCOL.read_text())
    for path, digest in protocol['filesSHA256'].items():
        if base.sha(ROOT / path) != digest: raise ValueError('sealed dependency drift: ' + path)
    return protocol


def smoke():
    for arm in ARMS:
        rows = install(arm)
        with tempfile.TemporaryDirectory() as folder:
            print('smoke', arm, len(rows), base.fit(arm, base.SEEDS[0], Path(folder), 1, max_updates=2, evaluate=False), flush=True)


def seal():
    if PROTOCOL.exists(): raise ValueError('protocol is sealed; use a new version')
    from retired_samples import RetiredSamples
    retired = RetiredSamples(); others = {p: base.read(ROOT / p) for p in [*base.SELECTION.values(), base.HISTORY, *base.ISOLATION]}
    report = {}
    for arm, spec in ARMS.items():
        rows = base.read(ROOT / spec['training']); leaks = base.overlap(rows, others)
        if any(leaks.values()): raise ValueError(f'{arm} holdout overlap {leaks}')
        flagged = Counter(retired.reason(r) for r in rows if retired.reason(r))
        if flagged: raise ValueError(f'{arm} retired rows {flagged}')
        report[arm] = dict(rows=len(rows), updates=base.window_plan(len(rows), 32, 4)['updatesPerEpoch'] * spec['epochs'])
    me = Path(__file__).resolve(); v88 = Path(base.__file__).resolve()
    files = [V52, ADMITTED, base.TRAINING, base.WEIGHTS, base.RUNTIME, base.SIMILARITY, base.HISTORY, *base.SELECTION.values(), *base.ISOLATION,
             'tools/apple-trainer/Training/signal-admission-v89-review.json', 'build/signal-rebuild-v88-20261103/verdict.json',
             *[base.SAM[s] + '/model.safetensors' for s in base.SEEDS], str(me.relative_to(ROOT)), str(v88.relative_to(ROOT))]
    PROTOCOL.write_text(json.dumps(dict(name=NAME, createdUTC=datetime.now(timezone.utc).isoformat(), arms=ARMS, common=base.COMMON | {'threads': THREADS},
        seeds=base.SEEDS, armBudgets=report, weights='v85 legacy weight for each (label, language) cell; not recomputed for new class counts. A Vietnamese cell absent from v85 uses the median Vietnamese weight.',
        selection='Same as v88: spent old493+dev636 only, policy action, strict fine, fewer normal-to-junk, earliest. Freeze before history.',
        questions=['free-v52 vs same-seed SAM: does the recipe alone beat SAM?', 'v88 warm-free (v85) vs free-v52: what do the 552 post-SAM rows add?',
                   'free-v89 vs v88 warm-free: do the 1,004 admitted rows help?'],
        signal='Recipe: v88 capability rule against SAM. Data: both seeds fine >= reference +.5pp, policy action >= reference, normal-to-junk at most +2, low-similarity history action >= reference -.5pp. No automatic replacement.',
        limits=['A first seal on the same day was removed before any training or scoring: a failed smoke test had been masked, and the weight fallback for one Vietnamese cell was added.', 'Epoch counts differ to match about 768 updates; visits per row differ.', 'All scored sets are exposed. Reserved 636 stays unscored.', 'Admitted rows are authored and assistant-reviewed.'],
        reservedScored=False, newIndependentFinal=False, releaseEligible=False, filesSHA256={f: base.sha(ROOT / f) for f in files}),
        ensure_ascii=False, indent=2) + '\n')
    print('sealed', report, flush=True)


def train(arm, seed):
    check(); install(arm); target = STORAGE / f'{arm}-{seed}'
    if target.exists(): raise ValueError('trial output exists: ' + str(target))
    base.fit(arm, seed, target, ARMS[arm]['epochs'])


def select():
    check(); results = {}; cohorts = {k: base.read(ROOT / p) for k, p in base.SELECTION.items()}; OUT.mkdir(exist_ok=True)
    for arm, spec in ARMS.items():
        for seed in base.SEEDS:
            trial = STORAGE / f'{arm}-{seed}'; records = []
            for epoch in range(spec['epochs'] + 1):
                parts = {}
                for name, rows in cohorts.items():
                    prefix = trial / f'epoch-{epoch:03d}-{name}'
                    parts[name] = base.replay(rows, base.read(f'{prefix}-predictions.ndjson'), prefix)[1]
                records.append(dict(epoch=epoch, **base.pooled(list(parts.values())), cohorts=parts))
            chosen = base.select_epoch(records)
            results[f'{arm}:{seed}'] = dict(selectedEpoch=chosen['epoch'], selected=chosen, curve=[{k: r[k] for k in ('epoch', 'policyActionCorrect', 'fineCorrect')} for r in records])
            print(arm, seed, 'epoch', chosen['epoch'], {k: chosen[k] for k in ('policyActionCorrect', 'fineCorrect', 'normalToJunk')}, flush=True)
    (OUT / 'selection.json').write_text(json.dumps(dict(historyUsed=False, results=results), indent=1) + '\n')


def verdict():
    check(); selected = json.loads((OUT / 'selection.json').read_text())['results']; folder = OUT / 'history'; folder.mkdir(exist_ok=False)
    history = base.read(ROOT / base.HISTORY); similarity = json.loads((ROOT / base.SIMILARITY).read_text())['similarity']
    actions = action_map(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))
    low = [similarity[base.text_id(r['text'])] < base.LOW_SIMILARITY for r in history]; arms = {}
    base.STORAGE = STORAGE
    for key, item in selected.items():
        arm, seed = key.split(':'); seed = int(seed); install(arm)
        decisions, metric = base.replay(history, base.checkpoint_predictions(arm, seed, item['selectedEpoch'], history), folder / f'{arm}-{seed}')
        arms[key] = dict(selectedEpoch=item['selectedEpoch'], selection={k: item['selected'][k] for k in ('policyActionCorrect', 'fineCorrect', 'normalToJunk', 'actionScored')},
            cohorts=item['selected']['cohorts'], history=dict(all=metric, lowSimilarity=score(
                [r for r, x in zip(history, low) if x], [d for d, x in zip(decisions, low) if x], actions)))
    v88 = json.loads((V88_OUT / 'verdict.json').read_text())
    signals = dict(recipeAlone=all(base._signal(arms[f'free-v52:{s}'], v88['references'][str(s)]) for s in base.SEEDS),
                   admittedData=all(data_signal(arms[f'free-v89:{s}'], v88['arms'][f'warm-free:{s}']) for s in base.SEEDS))
    (OUT / 'verdict.json').write_text(json.dumps(dict(arms=arms, signals=signals, reservedScored=False, automaticReplacement=False, releaseEligible=False), indent=1) + '\n')
    print('signals', signals, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('smoke', 'seal', 'train', 'select', 'verdict'))
    parser.add_argument('--arm', choices=tuple(ARMS)); parser.add_argument('--seed', type=int, choices=base.SEEDS)
    a = parser.parse_args()
    if a.stage == 'train': train(a.arm, a.seed)
    else: globals()[a.stage]()
