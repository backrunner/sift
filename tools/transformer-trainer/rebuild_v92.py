"""Test whether composed contrast rows that are new to the model add to warm-free.

V89 found 1,004 rows the model already knew did nothing. V92 fixes a novelty bar
before the current model sees the batch, trains only if the bar is met, and scores
96 development rows from families nothing has trained or screened on. It reuses the
v88 trainer and frozen runtime, never scores reserved rows, and cannot install a model.

Stages run in order: smoke, seal, screen, train --seed S, select, verdict.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile

import rebuild_v88 as base
import rebuild_v89 as v89
from evaluation_audit_v86 import action_map, score

ROOT = base.ROOT
NAME = 'signal-rebuild-v92'
OUT = ROOT / 'build/signal-rebuild-v92-20261104'
STORAGE = Path.home() / 'Library/Caches/SiftTraining' / OUT.name
PROTOCOL = ROOT / 'tools/transformer-trainer/experiments' / (NAME + '-protocol.json')
DATA = ROOT / 'build/signal-contrast-v92-20261104'
TRAINING = 'build/signal-contrast-v92-20261104/training.ndjson'
NEW = 'build/signal-contrast-v92-20261104/new-training.ndjson'
DEVELOPMENT = 'build/signal-contrast-v92-20261104/development.ndjson'
V88_VERDICT = 'build/signal-rebuild-v88-20261103/verdict.json'
ARM = 'free-v92'
SPEC = dict(init='sam', layers=12, lr=1e-5, epochs=23)
THREADS = 4
# Rows the current model already labels correctly added nothing in v89 (0.4% wrong);
# the batch that helped had about 45% wrong. Fixed before any screen ran.
MIN_NOVELTY = .20


def novelty_passes(wrong, total): return wrong >= MIN_NOVELTY * total


def development_signal(candidate, reference):
    """Fresh families must not get worse, on action or on fine label."""
    return bool(candidate['policyActionCorrect'] >= reference['policyActionCorrect']
                and candidate['fineCorrect'] >= reference['fineCorrect']
                and candidate['normalToJunk'] <= reference['normalToJunk'])


def install():
    base.ARMS[ARM] = {k: SPEC[k] for k in ('init', 'layers', 'lr')}
    base.STORAGE = STORAGE; base.PROTOCOL = PROTOCOL; base.COMMON['threads'] = THREADS
    rows = base.read(ROOT / TRAINING); weights = v89.weights_for(rows, v89.cell_weights())
    base.training_inputs = lambda: (rows, weights)
    return rows


def check():
    protocol = json.loads(PROTOCOL.read_text())
    for path, digest in protocol['filesSHA256'].items():
        if base.sha(ROOT / path) != digest: raise ValueError('sealed dependency drift: ' + path)
    return protocol


def smoke():
    rows = install()
    with tempfile.TemporaryDirectory() as folder:
        print('smoke', len(rows), base.fit(ARM, base.SEEDS[0], Path(folder), 1, max_updates=2, evaluate=False), flush=True)


def seal():
    if PROTOCOL.exists(): raise ValueError('protocol is sealed; use a new version')
    from retired_samples import RetiredSamples
    retired = RetiredSamples(); rows = base.read(ROOT / TRAINING); development = base.read(ROOT / DEVELOPMENT)
    others = {p: base.read(ROOT / p) for p in [*base.SELECTION.values(), base.HISTORY, *base.ISOLATION, DEVELOPMENT]}
    leaks = base.overlap(rows, others)
    if any(leaks.values()): raise ValueError(f'holdout overlap {leaks}')
    flagged = Counter(retired.reason(r) for r in rows if retired.reason(r))
    if flagged: raise ValueError(f'retired rows {flagged}')
    if {r['familyId'] for r in development} & {r.get('familyId') for r in rows}: raise ValueError('development family trained')
    updates = base.window_plan(len(rows), 32, 4)['updatesPerEpoch'] * SPEC['epochs']
    me = Path(__file__).resolve()
    files = [TRAINING, NEW, DEVELOPMENT, V88_VERDICT, base.TRAINING, base.WEIGHTS, base.RUNTIME, base.SIMILARITY, base.HISTORY, *base.SELECTION.values(), *base.ISOLATION,
             *[base.SAM[s] + '/model.safetensors' for s in base.SEEDS], 'build/signal-contrast-v92-20261104/admission.json',
             *[str(Path(__file__).with_name(n).relative_to(ROOT)) for n in ('author_contrast_v92.py', 'prepare_contrast_v92.py', 'rebuild_v88.py', 'rebuild_v89.py')], str(me.relative_to(ROOT))]
    PROTOCOL.write_text(json.dumps(dict(name=NAME, createdUTC=datetime.now(timezone.utc).isoformat(), arm=ARM, spec=SPEC, common=base.COMMON | {'threads': THREADS},
        seeds=base.SEEDS, rows=len(rows), newRows=len(rows) - len(base.read(ROOT / base.TRAINING)), updates=updates,
        novelty=dict(minWrongShare=MIN_NOVELTY, measure='Frozen-runtime engine label wrong on the new training rows, using v88 warm-free selected epochs, both seeds. No row is removed for being easy, and development rows are not screened. Below the bar, training does not run.'),
        selection='Same as v88: spent old493+dev636 only, policy action, strict fine, fewer normal-to-junk, earliest. Freeze before history and development.',
        signals=dict(data='v89 data rule against same-seed v88 warm-free, both seeds.', development='Fresh families, both seeds: policy action and fine label at or above warm-free, normal-to-junk at or below.'),
        reference='v88 warm-free, same seed, trained on the v85 pool without these rows.',
        limits=['Batch themes were chosen knowing the exposed real and official results; bodies were written from the rubric, not from any test row.', 'Rows are authored and assistant-reviewed, not observed SMS or native certified.', 'Development families share an author with training, so they measure transfer within this writing, not real traffic.', 'Reserved 636 stays unscored.'],
        reservedScored=False, automaticReplacement=False, releaseEligible=False, filesSHA256={f: base.sha(ROOT / f) for f in files}), ensure_ascii=False, indent=2) + '\n')
    print('sealed rows', len(rows), 'updates', updates, flush=True)


def actions(): return action_map(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))


def warm_epoch(seed): return json.loads((ROOT / V88_VERDICT).read_text())['arms'][f'warm-free:{seed}']['selectedEpoch']


def replay_warm(rows, seed, prefix):
    previous = base.STORAGE; base.STORAGE = Path.home() / 'Library/Caches/SiftTraining/signal-rebuild-v88-20261103'
    try: return base.replay(rows, base.checkpoint_predictions('warm-free', seed, warm_epoch(seed), rows), prefix)
    finally: base.STORAGE = previous


def screen():
    check(); OUT.mkdir(exist_ok=True); folder = OUT / 'screen'; folder.mkdir(exist_ok=False)
    rows = base.read(ROOT / NEW); result = {}; a = actions()
    for seed in base.SEEDS:
        decisions, _ = replay_warm(rows, seed, folder / f'warm-free-{seed}')
        wrong = [d['engineLabel'] != r['label'] for r, d in zip(rows, decisions, strict=True)]
        missed = Counter(r['filterReview']['kind'] for r, d in zip(rows, decisions) if d['engineAction'] != a[r['label']])
        byBoundary = Counter(r['boundary'] for r, w in zip(rows, wrong) if w)
        result[str(seed)] = dict(rows=len(rows), fineWrong=sum(wrong), actionWrongByKind=dict(missed), fineWrongByBoundary=dict(byBoundary), passed=novelty_passes(sum(wrong), len(rows)))
    result['authorized'] = all(result[str(s)]['passed'] for s in base.SEEDS)
    (OUT / 'screen.json').write_text(json.dumps(result, indent=1) + '\n'); print(result, flush=True)


def train(seed):
    check()
    if not json.loads((OUT / 'screen.json').read_text())['authorized']: raise ValueError('novelty bar not met; training is not authorized')
    install(); target = STORAGE / f'{ARM}-{seed}'
    if target.exists(): raise ValueError('trial output exists: ' + str(target))
    base.fit(ARM, seed, target, SPEC['epochs'])


def select():
    check(); results = {}; cohorts = {k: base.read(ROOT / p) for k, p in base.SELECTION.items()}
    for seed in base.SEEDS:
        trial = STORAGE / f'{ARM}-{seed}'; records = []
        for epoch in range(SPEC['epochs'] + 1):
            parts = {}
            for name, rows in cohorts.items():
                prefix = trial / f'epoch-{epoch:03d}-{name}'
                parts[name] = base.replay(rows, base.read(f'{prefix}-predictions.ndjson'), prefix)[1]
            records.append(dict(epoch=epoch, **base.pooled(list(parts.values())), cohorts=parts))
        chosen = base.select_epoch(records)
        results[f'{ARM}:{seed}'] = dict(selectedEpoch=chosen['epoch'], selected=chosen, curve=[{k: r[k] for k in ('epoch', 'policyActionCorrect', 'fineCorrect')} for r in records])
        print(seed, 'epoch', chosen['epoch'], {k: chosen[k] for k in ('policyActionCorrect', 'fineCorrect', 'normalToJunk')}, flush=True)
    (OUT / 'selection.json').write_text(json.dumps(dict(historyUsed=False, developmentUsed=False, results=results), indent=1) + '\n')


def verdict():
    check(); selected = json.loads((OUT / 'selection.json').read_text())['results']; folder = OUT / 'history'; folder.mkdir(exist_ok=False)
    history = base.read(ROOT / base.HISTORY); development = base.read(ROOT / DEVELOPMENT); a = actions()
    similarity = json.loads((ROOT / base.SIMILARITY).read_text())['similarity']
    low = [similarity[base.text_id(r['text'])] < base.LOW_SIMILARITY for r in history]
    v88 = json.loads((ROOT / V88_VERDICT).read_text())['arms']; arms = {}; signals = dict(data={}, development={}); install()
    for key, item in selected.items():
        seed = int(key.split(':')[1])
        decisions, metric = base.replay(history, base.checkpoint_predictions(ARM, seed, item['selectedEpoch'], history), folder / f'{ARM}-{seed}')
        candidate = arms[key] = dict(selectedEpoch=item['selectedEpoch'], selection={k: item['selected'][k] for k in ('policyActionCorrect', 'fineCorrect', 'normalToJunk', 'actionScored')},
            cohorts=item['selected']['cohorts'], history=dict(all=metric, lowSimilarity=score([r for r, x in zip(history, low) if x], [d for d, x in zip(decisions, low) if x], a)))
        _, dev = base.replay(development, base.checkpoint_predictions(ARM, seed, item['selectedEpoch'], development), folder / f'{ARM}-{seed}-development')
        _, ref = replay_warm(development, seed, folder / f'warm-free-{seed}-development')
        candidate['development'] = dev; candidate['developmentReference'] = ref
        signals['data'][str(seed)] = v89.data_signal(candidate, v88[f'warm-free:{seed}']); signals['development'][str(seed)] = development_signal(dev, ref)
    (OUT / 'verdict.json').write_text(json.dumps(dict(arms=arms, signals=signals, reservedScored=False, automaticReplacement=False, releaseEligible=False), indent=1) + '\n')
    print('signals', signals, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('smoke', 'seal', 'screen', 'train', 'select', 'verdict'))
    parser.add_argument('--seed', type=int, choices=base.SEEDS)
    a = parser.parse_args()
    if a.stage == 'train': train(a.seed)
    else: globals()[a.stage]()
