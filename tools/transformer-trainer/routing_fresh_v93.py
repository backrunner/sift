"""One fresh test of the routing settings v91 could only read after its results.

Settings are fixed before the v92 development rows open: bare encoder, head only and
gate epoch 36, on warm-free, free-v89 and free-v92, against retained SAM + v79. No
encoder training, and no fit touches development, holdout or reserved rows.

Stages run in order: seal, extract, score.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path

import rebuild_v88 as base
import rebuild_v92 as v92
import routing_refit_v91 as v91
from evaluation_audit_v86 import action_map
from recovery_routing_v75 import BRANCHES, gate, inputs, preferences
from study_expert_routing_v71 import head_values

ROOT = base.ROOT
NAME = 'signal-routing-v93'
OUT = ROOT / 'build/signal-routing-v93-20261104'
PROTOCOL = ROOT / 'tools/transformer-trainer/experiments' / (NAME + '-protocol.json')
V91_OUT = v91.OUT
ARMS = ('warm-free', 'free-v89', 'free-v92')
MODES = ('leaf', 'head', 'gate36')
GATE_EPOCH = 36
SEEDS = base.SEEDS
THREADS = 10
MIN_PROMOTION_TOLERANT = 149


def qualifies(candidate, reference, fixed, fixed_reference):
    """Per seed: no worse than SAM + v79 on fresh rows, and no regression on fixed suites."""
    return bool(candidate['policyActionCorrect'] >= reference['policyActionCorrect']
                and candidate['harmfulCaught'] >= reference['harmfulCaught']
                and candidate['normalToJunk'] <= reference['normalToJunk']
                and fixed['classification']['strictAction'] >= fixed_reference['classification']['strictAction']
                and fixed['promotion']['tolerantAction'] >= MIN_PROMOTION_TOLERANT
                and fixed['billing-card']['strictAction'] >= fixed_reference['billing-card']['strictAction'])


def rank(metrics):
    """Worst seed first, then harm caught, then fewer false blocks; ties stay in stable order."""
    return (min(m['policyActionCorrect'] for m in metrics), min(m['harmfulCaught'] for m in metrics),
            -max(m['normalToJunk'] for m in metrics))


def training_rows(arm):
    return base.read(ROOT / v92.TRAINING) if arm == 'free-v92' else v91.training_rows(arm)


def load_encoder(arm, seed):
    if arm != 'free-v92': return v91.load_encoder(arm, seed)
    import torch
    from transformers import AutoTokenizer
    path = ROOT / base.SAM[seed]; model = base.load_model(path)
    epoch = json.loads((v92.OUT / 'selection.json').read_text())['results'][f'{arm}:{seed}']['selectedEpoch']
    state = torch.load(v92.STORAGE / f'{arm}-{seed}/epoch-{epoch:03d}.pt', weights_only=True)['parameters']
    with torch.no_grad():
        for name, value in model.named_parameters():
            if name in state: value.copy_(state[name])
    return model, AutoTokenizer.from_pretrained(path, local_files_only=True)


def seal():
    if PROTOCOL.exists(): raise ValueError('protocol is sealed; use a new version')
    if (v92.OUT / 'verdict.json').exists(): raise ValueError('v92 development rows are already open')
    me = Path(__file__).resolve()
    files = [v92.DEVELOPMENT, v92.TRAINING, 'build/signal-rebuild-v92-20261104/selection.json', 'build/signal-routing-v91-20261104/union.ndjson',
             'build/signal-routing-v91-20261104/fit.json', 'tools/transformer-trainer/experiments/signal-routing-v91-protocol.json', base.RUNTIME,
             *[str(Path(__file__).with_name(n).relative_to(ROOT)) for n in ('routing_refit_v91.py', 'rebuild_v92.py', 'rebuild_v88.py')],
             str(me.with_name('tests').joinpath('test_routing_fresh_v93.py').relative_to(ROOT)), str(me.relative_to(ROOT))]
    PROTOCOL.write_text(json.dumps(dict(name=NAME, createdUTC=datetime.now(timezone.utc).isoformat(), arms=ARMS, modes=MODES, gateEpoch=GATE_EPOCH, seeds=SEEDS,
        comparator='Retained SAM + v79, unchanged.', fit='Head on encoder training rows. Gate on all 3,545 non-holdout union rows, v91 recipe.',
        freshRows='96 v92 development rows in 8 families; no model has scored them.',
        rule='A setting qualifies only if, in both seeds, development policy action and harmful caught are at or above SAM + v79, normal-to-junk at or below it, classification strict and billing at or above it, and promotion tolerant at least 149. Rank qualifiers by worst-seed action, harmful caught, then fewer normal-to-junk.',
        limits=['A first seal the same day was removed before any extraction or scoring: its score stage would have lost the v91 union and feature paths.', 'Gate 36 and head only were chosen after v91 union results, which is why they are tested here.', '96 rows from one author: small, correlated, and not real traffic. A qualifying setting authorizes further study, not replacement.', 'Union and real scores for new settings are reported as diagnostics only.', 'Reserved 636 stays unscored.'],
        reservedScored=False, automaticReplacement=False, releaseEligible=False, filesSHA256={f: base.sha(ROOT / f) for f in files}), ensure_ascii=False, indent=2) + '\n')
    print('sealed', flush=True)


def check():
    protocol = json.loads(PROTOCOL.read_text())
    for path, digest in protocol['filesSHA256'].items():
        if base.sha(ROOT / path) != digest: raise ValueError('sealed dependency drift: ' + path)
    return protocol


def suites():
    return {'development': base.read(ROOT / v92.DEVELOPMENT), 'union': base.read(V91_OUT / 'union.ndjson'), **v91.fixed_suites(), **v91.spent_sets()}


def feature_path(arm, seed, name):
    # score() points v91 replays at OUT, so v91's own features need a fixed path.
    existing = V91_OUT / f'features-{arm}-{seed}-{name}.pt'
    return existing if existing.exists() else OUT / f'features-{arm}-{seed}-{name}.pt'


def extract():
    import torch
    from study_action_head_v67 import extract_for_model
    check(); torch.set_num_threads(THREADS); sets = suites()
    for arm in ('sam', *ARMS):
        for seed in SEEDS:
            model, tokenizer = load_encoder(arm, seed) if arm != 'sam' else v91.load_encoder(arm, seed)
            for name, rows in {**sets, 'training': training_rows(arm) if arm != 'sam' else v91.training_rows(arm)}.items():
                path = feature_path(arm, seed, name)
                if not path.exists(): extract_for_model(model, tokenizer, rows, path)
    print('EXTRACT-DONE', flush=True)


def score_set(rows, cache, labels, head, g, tag, actions, name, mode, fixed):
    full = v91.full_predictions(cache, rows, labels)
    if mode == 'leaf':
        decisions = v91.swift(rows, full, tag)
    else:
        heads = head_values(head, cache['features'])
        prefs = [dict.fromkeys(BRANCHES, 1.) for _ in rows] if mode == 'head' else preferences(g, inputs(v91.GATE_ARM, full, heads, cache['features'], actions))
        decisions = v91.swift(rows, full, tag, heads, prefs)
    return v91.fixed_summary(rows, decisions, actions) if name in fixed else v91.summary(rows, decisions, actions)


def fit_full_gate(arm, seed, head, union, labels, actions, protected):
    import torch
    from expert_routing_v71 import targets
    from recovery_routing_v75 import branch_indices
    cache = torch.load(feature_path(arm, seed, 'union'), weights_only=True); full = v91.full_predictions(cache, union, labels)
    heads = head_values(head, cache['features']); index = v91.fit_indices(union, protected)
    leaf = v91.swift(union, full, f'{arm}-{seed}-fit-leaf'); routed = v91.swift(union, full, f'{arm}-{seed}-fit-head', heads, [dict.fromkeys(BRANCHES, 1.) for _ in union])
    y, w = targets([union[i] for i in index], [leaf[i] for i in index], [routed[i] for i in index], actions)
    x = inputs(v91.GATE_ARM, full, heads, cache['features'], actions)
    return v91.fit_gate(x[index], y, w, branch_indices([routed[i] for i in index]), seed, {GATE_EPOCH})[GATE_EPOCH]


def score():
    import torch
    from run_approved_signal import verify_checkpoint
    from study_fusion_v68 import model_manifest
    check(); torch.set_num_threads(THREADS); v91.OUT = OUT
    actions = action_map(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))
    sets = suites(); fixed = set(v91.fixed_suites()); protected = v91.protected_keys(v91.fixed_suites().values()); results = {}
    for seed in SEEDS:
        config = json.loads((ROOT / verify_checkpoint(model_manifest(seed))['checkpoint'] / 'config.json').read_text())
        labels = [config['id2label'][str(i)] for i in range(len(config['id2label']))]
        head = torch.nn.Linear(384, 4); head.load_state_dict(torch.load(v91.V75 / f'head-{seed}-full/epoch-018.pt', weights_only=True)); head.eval()
        g = gate(v91.GATE_ARM, seed); g.load_state_dict(torch.load(v91.V75 / f'gate-{v91.GATE_ARM}-{seed}/epoch-006.pt', weights_only=True)); g.eval()
        results[f'sam+v79:{seed}'] = {n: score_set(r, torch.load(feature_path('sam', seed, n), weights_only=True), labels, head, g, f'v79-{seed}-{n}', actions, n, 'gate36', fixed) for n, r in sets.items()}
        for arm in ARMS:
            rows = training_rows(arm); cache = torch.load(feature_path(arm, seed, 'training'), weights_only=True)
            head = v91.fit_head(cache['features'], rows, v91.training_weights('warm-free' if arm == 'free-v92' else arm, rows), seed)
            g = fit_full_gate(arm, seed, head, sets['union'], labels, actions, protected)
            torch.save(head.state_dict(), OUT / f'head-{arm}-{seed}.pt'); torch.save(g.state_dict(), OUT / f'gate-{arm}-{seed}.pt')
            for mode in MODES:
                results[f'{arm}/{mode}:{seed}'] = {n: score_set(r, torch.load(feature_path(arm, seed, n), weights_only=True), labels, head, g, f'{arm}-{seed}-{mode}-{n}', actions, n, mode, fixed) for n, r in sets.items()}
            print(arm, seed, {m: results[f'{arm}/{m}:{seed}']['development']['policyActionCorrect'] for m in MODES}, flush=True)
    settings = {}
    for arm in ARMS:
        for mode in MODES:
            key = f'{arm}/{mode}'
            passed = {str(s): qualifies(results[f'{key}:{s}']['development'], results[f'sam+v79:{s}']['development'], {n: results[f'{key}:{s}'][n] for n in fixed}, {n: results[f'sam+v79:{s}'][n] for n in fixed}) for s in SEEDS}
            settings[key] = dict(passed=passed, qualifies=all(passed.values()), rank=rank([results[f'{key}:{s}']['development'] for s in SEEDS]))
    qualifiers = [k for k, v in settings.items() if v['qualifies']]
    (OUT / 'verdict.json').write_text(json.dumps(dict(results=results, settings=settings, best=max(qualifiers, key=lambda k: settings[k]['rank']) if qualifiers else None,
        reservedScored=False, automaticReplacement=False, releaseEligible=False), indent=1) + '\n')
    print('SCORE-DONE', qualifiers, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('stage', choices=('seal', 'extract', 'score'))
    globals()[parser.parse_args().stage]()
