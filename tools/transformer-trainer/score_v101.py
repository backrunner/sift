#!/usr/bin/env python3
"""Score frozen v101 arms once on the sealed realistic test.

Stages: extract prepares features for the frozen epochs and every comparator. freeze fits heads and
gates and records hashes, then records the test as opened. score reads the test once and applies the sealed rule.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path

import evaluate_signal_v100 as evaluation
import rebuild_v101 as study
import rebuild_v88 as base
import rebuild_v89 as v89
import rebuild_v94 as v94
from recovery_routing_v75 import gate
import routing_fresh_v93 as v93
import routing_refit_v91 as v91

ROOT = base.ROOT
OUT = study.OUT
FLOOR_CLASSIFICATION_MARGIN = 2
MIN_PROMOTION_TOLERANT = 149
TEST = 'realistic287'
ARMS = tuple(study.ARMS)


def improves(comparison, candidate, reference, fixed, fixed_reference):
    """Sealed v101 rule for one seed. Positive differences favour the candidate."""
    serious = comparison['seriousFewerInA']
    return bool(candidate['serious'] <= reference['serious']
                and sum(candidate['errors'].values()) <= sum(reference['errors'].values())
                and serious['high'] >= 0
                and fixed['classification']['strictAction'] >= fixed_reference['classification']['strictAction'] - FLOOR_CLASSIFICATION_MARGIN
                and fixed['promotion']['tolerantAction'] >= MIN_PROMOTION_TOLERANT
                and fixed['billing-card']['strictAction'] >= fixed_reference['billing-card']['strictAction'])


def selected_epoch(arm, seed):
    return json.loads((OUT / 'selection.json').read_text())['results'][f'{arm}:{seed}']['selectedEpoch']


def load_encoder(arm, seed):
    if arm not in ARMS: return v93.load_encoder(arm, seed)
    import torch
    from transformers import AutoTokenizer
    path = ROOT / base.SAM[seed]; model = base.load_model(path); epoch = selected_epoch(arm, seed)
    state = torch.load(study.STORAGE / f'{arm}-{seed}/epoch-{epoch:03d}.pt', weights_only=True)['parameters']
    with torch.no_grad():
        for name, value in model.named_parameters():
            if name in state: value.copy_(state[name])
    return model, AutoTokenizer.from_pretrained(path, local_files_only=True)


def training_rows(arm):
    if arm in ARMS: return base.read(ROOT / study.ARMS[arm]['training'])
    return v93.training_rows(arm) if arm != 'sam' else v91.training_rows(arm)


def feature_path(arm, seed, name):
    for folder in (v93.V91_OUT, v93.OUT, v94.OUT):
        path = folder / f'features-{arm}-{seed}-{name}.pt'
        if path.exists(): return path
    return OUT / f'features-{arm}-{seed}-{name}.pt'


def open_suites():
    return {'union': base.read(v93.V91_OUT / 'union.ndjson'), **v91.fixed_suites(), **v91.spent_sets()}


def extract():
    import torch
    from study_action_head_v67 import extract_for_model
    study.check(); torch.set_num_threads(10); test = base.read(ROOT / study.DATA / 'test.ndjson')
    for arm in ('sam', 'free-v92', *ARMS):
        for seed in base.SEEDS:
            model, tokenizer = load_encoder(arm, seed)
            for name, rows in {**open_suites(), 'realistic287': test, 'training': training_rows(arm)}.items():
                path = feature_path(arm, seed, name)
                if not path.exists(): extract_for_model(model, tokenizer, rows, path)
    print('EXTRACT-DONE', flush=True)


def labels_for(seed):
    config = json.loads((ROOT / base.SAM[seed] / 'config.json').read_text())
    return [config['id2label'][str(i)] for i in range(len(config['id2label']))]


def freeze():
    import torch
    study.check(); torch.set_num_threads(10); v91.OUT = OUT; v93.feature_path = feature_path
    actions = evaluation.actions(); union = open_suites()['union']; protected = v91.protected_keys(v91.fixed_suites().values()); hashes = {}
    for seed in base.SEEDS:
        for arm in ARMS:
            rows = training_rows(arm); cache = torch.load(feature_path(arm, seed, 'training'), weights_only=True)
            head = v91.fit_head(cache['features'], rows, v89.weights_for(rows, v89.cell_weights()), seed)
            g = v93.fit_full_gate(arm, seed, head, union, labels_for(seed), actions, protected)
            for name, value in (('head', head), ('gate', g)):
                path = OUT / f'{name}-{arm}-{seed}.pt'; torch.save(value.state_dict(), path); hashes[path.name] = base.sha(path)
    (OUT / 'freeze.json').write_text(json.dumps(dict(createdUTC=datetime.now(timezone.utc).isoformat(), selectionSHA256=base.sha(OUT / 'selection.json'), filesSHA256=hashes, testRead=False), indent=1) + '\n')
    registry = json.loads(evaluation.REGISTRY.read_text()); spec = registry['sets'][TEST]
    if spec.get('opened'): raise ValueError('sealed test was already opened')
    spec.update(opened=True, openedUTC=datetime.now(timezone.utc).isoformat(), openedBy='signal-rebuild-v101')
    evaluation.REGISTRY.write_text(json.dumps(registry, ensure_ascii=False, indent=1) + '\n')
    print('FROZEN', flush=True)


def score():
    import torch
    study.check(); torch.set_num_threads(10); v91.OUT = OUT; v93.feature_path = feature_path
    if not json.loads(evaluation.REGISTRY.read_text())['sets'][TEST].get('opened'): raise ValueError('run freeze first')
    actions = evaluation.actions(); test = evaluation.load_set(TEST); fixed = v91.fixed_suites(); results = {}; decisions = {}
    sets = {**fixed, **v91.spent_sets(), TEST: test}
    frozen = json.loads((OUT / 'freeze.json').read_text())['filesSHA256']
    for name, digest in frozen.items():
        if base.sha(OUT / name) != digest: raise ValueError('frozen file changed: ' + name)
    def run(key, arm, seed, head, g, mode):
        out = {}
        for name, rows in sets.items():
            cache = torch.load(feature_path(arm, seed, name), weights_only=True)
            made = v94.replay_mode(rows, cache, labels_for(seed), head, g, f'{key.replace("/", "-")}-{seed}-{name}', actions, mode)
            out[name] = evaluation.report(rows, made, actions) if name not in fixed else v91.fixed_summary(rows, made, actions)
            if name == TEST: decisions[f'{key}:{seed}'] = made
        results[f'{key}:{seed}'] = out
    for seed in base.SEEDS:
        head = torch.nn.Linear(384, 4); head.load_state_dict(torch.load(v91.V75 / f'head-{seed}-full/epoch-018.pt', weights_only=True)); head.eval()
        g = gate(v91.GATE_ARM, seed); g.load_state_dict(torch.load(v91.V75 / f'gate-{v91.GATE_ARM}-{seed}/epoch-006.pt', weights_only=True)); g.eval()
        run('sam+v79', 'sam', seed, head, g, 'gate36')
        head = torch.nn.Linear(384, 4); head.load_state_dict(torch.load(v94.OUT / f'head-free-v92-{seed}.pt', weights_only=True)); head.eval()
        g = gate(v91.GATE_ARM, seed); g.load_state_dict(torch.load(v94.OUT / f'gate-free-v92-{seed}.pt', weights_only=True)); g.eval()
        run('free-v92/gate36', 'free-v92', seed, head, g, 'gate36')
        for arm in ARMS:
            head = torch.nn.Linear(384, 4); head.load_state_dict(torch.load(OUT / f'head-{arm}-{seed}.pt', weights_only=True)); head.eval()
            g = gate(v91.GATE_ARM, seed); g.load_state_dict(torch.load(OUT / f'gate-{arm}-{seed}.pt', weights_only=True)); g.eval()
            for mode in ('gate36', 'leaf'): run(f'{arm}/{mode}', arm, seed, head, g, mode)
    signals = {}; comparisons = {}
    for arm in ARMS:
        for seed in base.SEEDS:
            key = f'{arm}/gate36:{seed}'; reference = f'free-v92/gate36:{seed}'
            comparison = evaluation.compare(test, decisions[key], decisions[reference], actions); comparisons[key] = comparison
            signals[key] = improves(comparison, results[key][TEST], results[reference][TEST], results[key], results[reference])
    for key in decisions:
        if key.startswith('free-v92'): comparisons[key + ' vs sam+v79'] = evaluation.compare(test, decisions[key], decisions[f'sam+v79:{key.split(":")[1]}'], actions)
    (OUT / 'verdict.json').write_text(json.dumps(dict(results=results, signals=signals, comparisons=comparisons, passed={a: all(signals[f'{a}/gate36:{s}'] for s in base.SEEDS) for a in ARMS}, reservedScored=False, automaticReplacement=False, releaseEligible=False), ensure_ascii=False, indent=1) + '\n')
    print('SCORE-DONE', signals, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('stage', choices=('extract', 'freeze', 'score'))
    globals()[parser.parse_args().stage]()
