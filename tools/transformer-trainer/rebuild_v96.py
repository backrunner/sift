"""Test whether composed zh and ja families add to the v94 winner.

Same recipe as both-v94 with the new rows added. A novelty bar is fixed before the
current model reads the batch. Candidates freeze on spent rows, then 64 untrained rows
and the unscored 79-row real set open once. Cannot install a model.

Stages run in order: smoke, seal, screen, train --seed S, select, extract, score.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile

from evaluation_audit_v86 import action_map
import rebuild_v88 as base
import rebuild_v89 as v89
import rebuild_v92 as v92
import rebuild_v94 as v94
from recovery_routing_v75 import BRANCHES, gate, inputs, preferences
import routing_fresh_v93 as v93
import routing_refit_v91 as v91
from study_expert_routing_v71 import head_values

ROOT = base.ROOT
NAME = 'signal-rebuild-v96'
OUT = ROOT / 'build/signal-rebuild-v96-20261104'
STORAGE = Path.home() / 'Library/Caches/SiftTraining' / OUT.name
PROTOCOL = ROOT / 'tools/transformer-trainer/experiments' / (NAME + '-protocol.json')
DATA = ROOT / 'build/signal-cjk-v96-20261104'
TRAINING = 'build/signal-rebuild-v96-20261104/training.ndjson'
NEW = 'build/signal-cjk-v96-20261104/new-training.ndjson'
DEVELOPMENT = 'build/signal-cjk-v96-20261104/development.ndjson'
REAL = 'build/signal-real-v95-20261104/test-real.ndjson'
ARM = 'cjk-v96'
EPOCHS = 22
THREADS = 4
REFERENCE = 'both-v94'
MIN_NOVELTY = .20
CLASSIFICATION_MARGIN = 2
LINK_SERIOUS_MARGIN = 1
REAL_SERIOUS_MARGIN = 1
ACTION_MARGIN = 1
ARMS = (ARM, REFERENCE)


def novelty_passes(wrong, total): return wrong >= MIN_NOVELTY * total


def improves(c, r):
    """Per seed against the v94 winner: better or equal on new rows, no cost elsewhere."""
    s = v94.serious
    return bool(s(c['development']['errors']) <= s(r['development']['errors'])
                and c['development']['policyActionCorrect'] >= r['development']['policyActionCorrect'] - ACTION_MARGIN
                and s(c['fresh']['errors']) <= s(r['fresh']['errors']) + LINK_SERIOUS_MARGIN
                and s(c['real']['errors']) <= s(r['real']['errors']) + REAL_SERIOUS_MARGIN
                and c['classification']['strictAction'] >= r['classification']['strictAction'] - CLASSIFICATION_MARGIN
                and c['promotion']['tolerantAction'] >= v94.MIN_PROMOTION_TOLERANT
                and c['billing-card']['strictAction'] >= r['billing-card']['strictAction'])


def install():
    v94.ARMS[ARM] = dict(training=TRAINING, joint=True); v94.STORAGE = STORAGE; v94.PROTOCOL = PROTOCOL
    v94.SPEC = {**v94.SPEC, 'epochs': EPOCHS}; v94.THREADS = THREADS
    return v94.install(ARM)


def check():
    protocol = json.loads(PROTOCOL.read_text())
    for path, digest in protocol['filesSHA256'].items():
        if base.sha(ROOT / path) != digest: raise ValueError('sealed dependency drift: ' + path)
    return protocol


def combine():
    OUT.mkdir(exist_ok=True); target = ROOT / TRAINING
    if target.exists(): return
    rows = base.read(ROOT / v94.HOSTS) + base.read(ROOT / NEW); base.dump(target, rows)


def smoke():
    combine(); rows = install()
    with tempfile.TemporaryDirectory() as folder:
        print('smoke', len(rows), base.fit(ARM, base.SEEDS[0], Path(folder), 1, max_updates=2, evaluate=False), flush=True)


def seal():
    if PROTOCOL.exists(): raise ValueError('protocol is sealed; use a new version')
    from retired_samples import RetiredSamples
    combine(); rows = base.read(ROOT / TRAINING); retired = RetiredSamples()
    others = {p: base.read(ROOT / p) for p in [*base.SELECTION.values(), base.HISTORY, *base.ISOLATION, v94.FRESH, DEVELOPMENT, REAL]}
    leaks = base.overlap(rows, others)
    if any(leaks.values()): raise ValueError(f'holdout overlap {leaks}')
    flagged = Counter(retired.reason(r) for r in rows if retired.reason(r))
    if flagged: raise ValueError(f'retired rows {flagged}')
    updates = base.window_plan(len(rows), 32, 4)['updatesPerEpoch'] * EPOCHS; me = Path(__file__).resolve()
    files = [TRAINING, NEW, DEVELOPMENT, REAL, v94.HOSTS, v94.FRESH, 'build/signal-rebuild-v94-20261104/verdict.json', 'build/signal-rebuild-v94-20261104/selection.json', 'build/signal-cjk-v96-20261104/admission.json', 'build/signal-real-v95-20261104/manifest.json', base.RUNTIME,
             *[str(me.with_name(n).relative_to(ROOT)) for n in ('author_cjk_v96.py', 'prepare_cjk_v96.py', 'rebuild_v94.py', 'rebuild_v92.py', 'rebuild_v89.py', 'rebuild_v88.py', 'routing_fresh_v93.py', 'routing_refit_v91.py')],
             str(me.with_name('tests').joinpath('test_rebuild_v96.py').relative_to(ROOT)), str(me.relative_to(ROOT))]
    PROTOCOL.write_text(json.dumps(dict(name=NAME, createdUTC=datetime.now(timezone.utc).isoformat(), arm=ARM, recipe='both-v94: hosts data plus jointly trained action head', epochs=EPOCHS, rows=len(rows), updates=updates, seeds=base.SEEDS,
        novelty=dict(minWrongShare=MIN_NOVELTY, measure='Frozen-runtime engine label wrong on the 192 new rows using both-v94 selected epochs, both seeds. Below the bar, training does not run.'),
        selection='Same as v88 on spent old493+dev636, frozen before any test opens.', setting='Gate 36 only, the v94 winning setting. Bare encoder reported as a diagnostic.',
        signal=f'Per seed against both-v94 gate 36: serious errors on the 64 development rows at or below it and action at most {ACTION_MARGIN} below it; link test serious at most +{LINK_SERIOUS_MARGIN}; 79 real rows serious at most +{REAL_SERIOUS_MARGIN}; classification strict at most {CLASSIFICATION_MARGIN} below; promotion tolerant at least {v94.MIN_PROMOTION_TOLERANT}; billing at or above.',
        scored=dict(unscored=['64 zh and ja development rows', '79 real rows, held back from v94 so all candidates meet it once'], exposed=['180-row link test, read by v94', '45 real-visible', 'fixed suites', 'union']),
        limits=['Batch and development rows are assistant-authored, not received messages, with no native review.', 'The 79 real rows are English and dated, so they cannot show zh or ja benefit.', 'Gate fits non-holdout union rows; union scores for gate settings are in-sample.', 'Reserved 636 stays unscored.'],
        reservedScored=False, automaticReplacement=False, releaseEligible=False, filesSHA256={f: base.sha(ROOT / f) for f in files}), ensure_ascii=False, indent=2) + '\n')
    print('sealed rows', len(rows), 'updates', updates, flush=True)


def load_encoder(arm, seed):
    import torch
    from transformers import AutoTokenizer
    path = ROOT / base.SAM[seed]; model = base.load_model(path)
    if arm != 'sam':
        folder, store = (OUT, STORAGE) if arm == ARM else (v94.OUT, v94_store())
        epoch = json.loads((folder / 'selection.json').read_text())['results'][f'{arm}:{seed}']['selectedEpoch']
        state = torch.load(store / f'{arm}-{seed}/epoch-{epoch:03d}.pt', weights_only=True)['parameters']
        with torch.no_grad():
            for name, value in model.named_parameters():
                if name in state: value.copy_(state[name])
    return model, AutoTokenizer.from_pretrained(path, local_files_only=True)


def v94_store(): return Path.home() / 'Library/Caches/SiftTraining' / v94.OUT.name


def screen():
    check(); folder = OUT / 'screen'; folder.mkdir(exist_ok=False); rows = base.read(ROOT / NEW); result = {}
    actions = action_map(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))
    for seed in base.SEEDS:
        model, tokenizer = load_encoder(REFERENCE, seed)
        decisions, _ = base.replay(rows, base.predict(model, tokenizer, rows), folder / f'{REFERENCE}-{seed}')
        wrong = [d['engineLabel'] != r['label'] for r, d in zip(rows, decisions, strict=True)]
        errors = Counter(e for r, d in zip(rows, decisions) if (e := v94.error_type(r, d, actions)))
        result[str(seed)] = dict(rows=len(rows), fineWrong=sum(wrong), errors=dict(errors), byLanguage=dict(Counter(r['language'] for r, w in zip(rows, wrong) if w)), passed=novelty_passes(sum(wrong), len(rows)))
    result['authorized'] = all(result[str(s)]['passed'] for s in base.SEEDS)
    (OUT / 'screen.json').write_text(json.dumps(result, indent=1) + '\n'); print(result, flush=True)


def train(seed):
    check()
    if not json.loads((OUT / 'screen.json').read_text())['authorized']: raise ValueError('novelty bar not met; training is not authorized')
    install(); target = STORAGE / f'{ARM}-{seed}'
    if target.exists(): raise ValueError('trial output exists: ' + str(target))
    base.fit(ARM, seed, target, EPOCHS)


def select():
    check(); results = {}; cohorts = {k: base.read(ROOT / p) for k, p in base.SELECTION.items()}
    for seed in base.SEEDS:
        trial = STORAGE / f'{ARM}-{seed}'; records = []
        for epoch in range(EPOCHS + 1):
            parts = {name: base.replay(rows, base.read(trial / f'epoch-{epoch:03d}-{name}-predictions.ndjson'), trial / f'epoch-{epoch:03d}-{name}')[1] for name, rows in cohorts.items()}
            records.append(dict(epoch=epoch, **base.pooled(list(parts.values()))))
        chosen = base.select_epoch(records)
        results[f'{ARM}:{seed}'] = dict(selectedEpoch=chosen['epoch'], selected={k: chosen[k] for k in ('policyActionCorrect', 'fineCorrect', 'normalToJunk', 'actionScored')})
        print(seed, results[f'{ARM}:{seed}'], flush=True)
    (OUT / 'selection.json').write_text(json.dumps(dict(testsUsed=False, results=results), indent=1) + '\n')


def suites():
    return dict(development=base.read(ROOT / DEVELOPMENT), real=base.read(ROOT / REAL), fresh=base.read(ROOT / v94.FRESH), union=base.read(v93.V91_OUT / 'union.ndjson'), **v91.fixed_suites(), **v91.spent_sets())


def training_rows(arm):
    return base.read(ROOT / TRAINING) if arm == ARM else base.read(ROOT / v94.HOSTS) if arm == REFERENCE else v91.training_rows(arm)


def feature_path(arm, seed, name):
    for folder in (v93.V91_OUT, v93.OUT, v94.OUT):
        path = folder / f'features-{arm}-{seed}-{name}.pt'
        if path.exists(): return path
    return OUT / f'features-{arm}-{seed}-{name}.pt'


def extract():
    import torch
    from study_action_head_v67 import extract_for_model
    check(); torch.set_num_threads(10); sets = suites()
    for arm in ('sam', *ARMS):
        for seed in base.SEEDS:
            model, tokenizer = load_encoder(arm, seed)
            for name, rows in {**sets, 'training': training_rows(arm)}.items():
                path = feature_path(arm, seed, name)
                if not path.exists(): extract_for_model(model, tokenizer, rows, path)
    print('EXTRACT-DONE', flush=True)


def joint_head(store, arm, seed, folder):
    import torch
    epoch = json.loads((folder / 'selection.json').read_text())['results'][f'{arm}:{seed}']['selectedEpoch']
    state = torch.load(store / f'{arm}-{seed}/epoch-{epoch:03d}.pt', weights_only=True)['parameters']; head = torch.nn.Linear(384, 4)
    head.load_state_dict({'weight': state['action_head.weight'], 'bias': state['action_head.bias']}); return head.eval()


def score():
    import torch
    from run_approved_signal import verify_checkpoint
    from study_fusion_v68 import model_manifest
    check(); torch.set_num_threads(10); v91.OUT = OUT; v93.feature_path = feature_path
    actions = action_map(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))
    sets = suites(); fixed = set(v91.fixed_suites()); protected = v91.protected_keys(v91.fixed_suites().values()); results = {}
    (OUT / 'score-start.json').write_text(json.dumps(dict(protocolSHA256=base.sha(PROTOCOL), selectionSHA256=base.sha(OUT / 'selection.json'))) + '\n')
    def measure(rows, cache, labels, head, g, tag, name, mode):
        return v94.measured(rows, v94.replay_mode(rows, cache, labels, head, g, tag, actions, mode), actions, 'fresh' if name in ('fresh', 'development', 'real') else name, fixed)
    for seed in base.SEEDS:
        config = json.loads((ROOT / verify_checkpoint(model_manifest(seed))['checkpoint'] / 'config.json').read_text())
        labels = [config['id2label'][str(i)] for i in range(len(config['id2label']))]
        head = torch.nn.Linear(384, 4); head.load_state_dict(torch.load(v91.V75 / f'head-{seed}-full/epoch-018.pt', weights_only=True)); head.eval()
        g = gate(v91.GATE_ARM, seed); g.load_state_dict(torch.load(v91.V75 / f'gate-{v91.GATE_ARM}-{seed}/epoch-006.pt', weights_only=True)); g.eval()
        results[f'sam+v79:{seed}'] = {n: measure(r, torch.load(feature_path('sam', seed, n), weights_only=True), labels, head, g, f'v79-{seed}-{n}', n, 'gate36') for n, r in sets.items()}
        for arm, folder, store in ((REFERENCE, v94.OUT, v94_store()), (ARM, OUT, STORAGE)):
            head = joint_head(store, arm, seed, folder)
            if arm == REFERENCE:
                g = gate(v91.GATE_ARM, seed); g.load_state_dict(torch.load(v94.OUT / f'gate-{arm}-{seed}.pt', weights_only=True)); g.eval()
            else:
                g = v93.fit_full_gate(arm, seed, head, sets['union'], labels, actions, protected); torch.save(g.state_dict(), OUT / f'gate-{arm}-{seed}.pt')
            for mode in ('leaf', 'gate36'):
                results[f'{arm}/{mode}:{seed}'] = {n: measure(r, torch.load(feature_path(arm, seed, n), weights_only=True), labels, head, g, f'{arm}-{seed}-{mode}-{n}', n, mode) for n, r in sets.items()}
            print(arm, seed, {m: {n: (results[f'{arm}/{m}:{seed}'][n]['policyActionCorrect'], v94.serious(results[f'{arm}/{m}:{seed}'][n]['errors'])) for n in ('development', 'real')} for m in ('leaf', 'gate36')}, flush=True)
    signal = {str(s): improves(results[f'{ARM}/gate36:{s}'], results[f'{REFERENCE}/gate36:{s}']) for s in base.SEEDS}
    (OUT / 'verdict.json').write_text(json.dumps(dict(results=results, signal=signal, passed=all(signal.values()), reservedScored=False, automaticReplacement=False, releaseEligible=False), indent=1) + '\n')
    print('SCORE-DONE', signal, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('smoke', 'seal', 'screen', 'train', 'select', 'extract', 'score'))
    parser.add_argument('--seed', type=int, choices=base.SEEDS)
    a = parser.parse_args()
    if a.stage == 'train': train(a.seed)
    else: globals()[a.stage]()
