"""Train around the validation audit: realistic link hosts and a jointly trained action head.

The audit found hosts barely measured, real hosts teaching spam, and action accuracy
dominated by filing errors. V94 tests both changes against a 180-row link test written
before any model saw it, reports serious errors apart, and uses a margin rather than a
one-row bar. It reuses the v88 trainer and frozen runtime, and cannot install a model.

Stages run in order: smoke, seal, train --arm A --seed S, select, extract, score.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile

from evaluation_audit_v86 import action_map
from harm_separation_v73 import separated_loss
from action_head_v67 import target
import rebuild_v88 as base
import rebuild_v89 as v89
import rebuild_v92 as v92
from recovery_routing_v75 import BRANCHES, gate, inputs, preferences
import routing_fresh_v93 as v93
import routing_refit_v91 as v91
from study_expert_routing_v71 import head_values

ROOT = base.ROOT
NAME = 'signal-rebuild-v94'
OUT = ROOT / 'build/signal-rebuild-v94-20261104'
STORAGE = Path.home() / 'Library/Caches/SiftTraining' / OUT.name
PROTOCOL = ROOT / 'tools/transformer-trainer/experiments' / (NAME + '-protocol.json')
DATA = 'build/signal-validation-v94-20261104'
HOSTS = f'{DATA}/training-hosts.ndjson'
FRESH = f'{DATA}/fresh.ndjson'
ARMS = {'hosts-v94': dict(training=HOSTS, joint=False), 'joint-v94': dict(training=v92.TRAINING, joint=True), 'both-v94': dict(training=HOSTS, joint=True)}
SPEC = dict(init='sam', layers=12, lr=1e-5, epochs=23)
# The action head starts at zero, so it needs v75's head rate rather than the encoder's.
JOINT = dict(weight=.5, headLr=1e-3, headDecay=.01)
THREADS = 3
MODES = ('leaf', 'head', 'gate36')
ACTION_MARGIN = 2
CLASSIFICATION_MARGIN = 2
MIN_PROMOTION_TOLERANT = 149
SERIOUS = ('harmful missed', 'normal to junk', 'normal to promotion')


def error_type(row, decision, actions):
    kind = row['filterReview']['kind']; action = decision['engineAction']; expected = actions[row['label']]
    if kind == 'harmful': return None if action == 'junk' else 'harmful missed'
    if kind == 'commercial': return None if action in ('promotion', 'junk') else 'commercial missed'
    if action == expected: return None
    return {'junk': 'normal to junk', 'promotion': 'normal to promotion'}.get(action, 'transaction vs none')


def serious(errors): return sum(errors.get(k, 0) for k in SERIOUS)


def qualifies(fresh, reference, fixed, fixed_reference, real, real_reference):
    """Per seed: fewer or equal serious errors, action within a margin, no regression elsewhere."""
    return bool(serious(fresh['errors']) <= serious(reference['errors'])
                and fresh['policyActionCorrect'] >= reference['policyActionCorrect'] - ACTION_MARGIN
                and fixed['classification']['strictAction'] >= fixed_reference['classification']['strictAction'] - CLASSIFICATION_MARGIN
                and fixed['promotion']['tolerantAction'] >= MIN_PROMOTION_TOLERANT
                and fixed['billing-card']['strictAction'] >= fixed_reference['billing-card']['strictAction']
                and real['harmfulCaught'] >= real_reference['harmfulCaught'])


def rank(metrics):
    return (-max(serious(m['errors']) for m in metrics), min(m['policyActionCorrect'] for m in metrics), min(m['fineCorrect'] for m in metrics))


def attach_joint(model):
    """Add a four-action head that sees the classifier input; gradients reach the encoder."""
    import torch
    model.action_head = torch.nn.Linear(model.config.hidden_size, 4)
    torch.nn.init.zeros_(model.action_head.weight); torch.nn.init.zeros_(model.action_head.bias)
    model.classifier.register_forward_pre_hook(lambda _m, inputs: setattr(model, 'pooled', inputs[0]))
    return model


def joint_groups(original):
    def build(model, *args, **kwargs):
        groups, report = original(model, *args, **kwargs)
        head = list(model.action_head.parameters()); ids = {id(p) for p in head}
        for group in groups: group['params'] = [p for p in group['params'] if id(p) not in ids]
        groups = [g for g in groups if g['params']]
        groups.append(dict(params=head, lr=JOINT['headLr'], weight_decay=JOINT['headDecay']))
        return groups, report + [dict(learningRate=JOINT['headLr'], weightDecay=JOINT['headDecay'], tensorCount=2, parameterCount=sum(p.numel() for p in head), nameExamples=['action_head.weight'])]
    return build


def joint_objective(original, holder, id_to_action):
    import torch
    weights = torch.tensor(v91.CLASS_WEIGHTS, dtype=torch.float32)
    def objective(logits, labels, label_to_id):
        model = holder['model']; y = id_to_action[labels]
        return original(logits, labels, label_to_id) + JOINT['weight'] * separated_loss(model.action_head(model.pooled), y) * weights[y]
    return objective


def install(arm):
    import torch
    spec = ARMS[arm]; base.ARMS[arm] = {k: SPEC[k] for k in ('init', 'layers', 'lr')}
    base.STORAGE = STORAGE; base.PROTOCOL = PROTOCOL; base.COMMON['threads'] = THREADS
    rows = base.read(ROOT / spec['training']); weights = v89.weights_for(rows, v89.cell_weights())
    base.training_inputs = lambda: (rows, weights)
    if spec['joint']:
        holder = {}; loader = base.load_model; actions = action_map(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))
        def load(path, dropout=0.):
            model = attach_joint(loader(path, dropout)); holder['model'] = model
            base.commercial_objective = joint_objective(plain, holder, torch.tensor([target(model.config.id2label[i], actions) for i in range(model.config.num_labels)]))
            return model
        plain = base.commercial_objective; base.load_model = load; base.parameter_groups = joint_groups(base.parameter_groups)
    return rows


def check():
    protocol = json.loads(PROTOCOL.read_text())
    for path, digest in protocol['filesSHA256'].items():
        if base.sha(ROOT / path) != digest: raise ValueError('sealed dependency drift: ' + path)
    return protocol


def smoke():
    loader, groups, objective = base.load_model, base.parameter_groups, base.commercial_objective
    for arm in ARMS:
        rows = install(arm)
        with tempfile.TemporaryDirectory() as folder:
            print('smoke', arm, len(rows), base.fit(arm, base.SEEDS[0], Path(folder), 1, max_updates=2, evaluate=False), flush=True)
        base.load_model, base.parameter_groups, base.commercial_objective = loader, groups, objective


def seal():
    if PROTOCOL.exists(): raise ValueError('protocol is sealed; use a new version')
    from retired_samples import RetiredSamples
    retired = RetiredSamples(); fresh = base.read(ROOT / FRESH); report = {}
    others = {p: base.read(ROOT / p) for p in [*base.SELECTION.values(), base.HISTORY, *base.ISOLATION, FRESH]}
    for arm, spec in ARMS.items():
        rows = base.read(ROOT / spec['training']); leaks = base.overlap(rows, others)
        if any(leaks.values()): raise ValueError(f'{arm} holdout overlap {leaks}')
        flagged = Counter(retired.reason(r) for r in rows if retired.reason(r))
        if flagged: raise ValueError(f'{arm} retired rows {flagged}')
        report[arm] = dict(rows=len(rows), updates=base.window_plan(len(rows), 32, 4)['updatesPerEpoch'] * SPEC['epochs'])
    me = Path(__file__).resolve()
    files = [HOSTS, FRESH, v92.TRAINING, f'{DATA}/admission.json', base.RUNTIME, base.WEIGHTS, base.TRAINING, base.HISTORY, *base.SELECTION.values(), *base.ISOLATION,
             'build/signal-rebuild-v92-20261104/selection.json', 'build/signal-routing-v91-20261104/union.ndjson', *[base.SAM[s] + '/model.safetensors' for s in base.SEEDS],
             *[str(me.with_name(n).relative_to(ROOT)) for n in ('author_fresh_v94.py', 'prepare_fresh_v94.py', 'rebuild_v88.py', 'rebuild_v89.py', 'rebuild_v92.py', 'routing_fresh_v93.py', 'routing_refit_v91.py', 'audit_validation_v94.py')],
             str(me.with_name('tests').joinpath('test_rebuild_v94.py').relative_to(ROOT)), str(me.relative_to(ROOT))]
    PROTOCOL.write_text(json.dumps(dict(name=NAME, createdUTC=datetime.now(timezone.utc).isoformat(), arms=ARMS, spec=SPEC, joint=JOINT, common=base.COMMON | {'threads': THREADS}, seeds=base.SEEDS, armBudgets=report,
        selection='Same as v88 on spent old493+dev636, using bare-encoder decisions, frozen before the link test.',
        reference='Retained SAM + v79, and the v93 lead free-v92 gate 36, on the same rows.',
        settings='Each arm in bare, head and gate-36 modes. Joint arms use their trained action head. Others fit v75 heads. Gates use the v91 recipe on non-holdout union rows.',
        rule=f'Both seeds on the link test: serious errors (harmful missed, normal to junk, normal to promotion) at or below SAM + v79; policy action at most {ACTION_MARGIN} rows below it. Classification strict at most {CLASSIFICATION_MARGIN} below it, promotion tolerant at least {MIN_PROMOTION_TOLERANT}, billing at or above it, real-visible harmful at or above it. Rank by worst-seed serious errors, action, then fine.',
        limits=['The link test is assistant-authored with fictional hosts: it measures this boundary, not real traffic.', 'Epochs are selected on a pool without real-host normal rows, so selection cannot see the host effect.', 'Gate rows may fit union rows with .invalid hosts.', 'The real-visible set is spent and small; its use here is a floor only.', 'A qualifying setting authorizes further study. Reserved 636 stays unscored: it holds 12 harmful rows and no links.'],
        reservedScored=False, automaticReplacement=False, releaseEligible=False, filesSHA256={f: base.sha(ROOT / f) for f in files}), ensure_ascii=False, indent=2) + '\n')
    print('sealed', report, flush=True)


def train(arm, seed):
    check(); install(arm); target_path = STORAGE / f'{arm}-{seed}'
    if target_path.exists(): raise ValueError('trial output exists: ' + str(target_path))
    base.fit(arm, seed, target_path, SPEC['epochs'])


def select():
    check(); OUT.mkdir(exist_ok=True); results = {}; cohorts = {k: base.read(ROOT / p) for k, p in base.SELECTION.items()}
    for arm in ARMS:
        for seed in base.SEEDS:
            trial = STORAGE / f'{arm}-{seed}'; records = []
            for epoch in range(SPEC['epochs'] + 1):
                parts = {}
                for name, rows in cohorts.items():
                    prefix = trial / f'epoch-{epoch:03d}-{name}'
                    parts[name] = base.replay(rows, base.read(f'{prefix}-predictions.ndjson'), prefix)[1]
                records.append(dict(epoch=epoch, **base.pooled(list(parts.values())), cohorts=parts))
            chosen = base.select_epoch(records)
            results[f'{arm}:{seed}'] = dict(selectedEpoch=chosen['epoch'], selected={k: chosen[k] for k in ('policyActionCorrect', 'fineCorrect', 'normalToJunk', 'actionScored')})
            print(arm, seed, results[f'{arm}:{seed}'], flush=True)
    (OUT / 'selection.json').write_text(json.dumps(dict(linkTestUsed=False, results=results), indent=1) + '\n')


def checkpoint(arm, seed):
    epoch = json.loads((OUT / 'selection.json').read_text())['results'][f'{arm}:{seed}']['selectedEpoch']
    return STORAGE / f'{arm}-{seed}/epoch-{epoch:03d}.pt'


def load_encoder(arm, seed):
    if arm not in ARMS: return v93.load_encoder(arm, seed)
    import torch
    from transformers import AutoTokenizer
    path = ROOT / base.SAM[seed]; model = base.load_model(path); state = torch.load(checkpoint(arm, seed), weights_only=True)['parameters']
    with torch.no_grad():
        for name, value in model.named_parameters():
            if name in state: value.copy_(state[name])
    return model, AutoTokenizer.from_pretrained(path, local_files_only=True)


def training_rows(arm):
    if arm in ARMS: return base.read(ROOT / ARMS[arm]['training'])
    return v93.training_rows(arm) if arm != 'sam' else v91.training_rows(arm)


def suites():
    return {'fresh': base.read(ROOT / FRESH), 'union': base.read(v93.V91_OUT / 'union.ndjson'), **fixed_suites(), **spent_sets()}


FIXED = v91.fixed_suites; SPENT = v91.spent_sets
def fixed_suites(): return FIXED()
def spent_sets(): return SPENT()


def feature_path(arm, seed, name):
    for folder in (v93.V91_OUT, v93.OUT):
        path = folder / f'features-{arm}-{seed}-{name}.pt'
        if path.exists(): return path
    return OUT / f'features-{arm}-{seed}-{name}.pt'


def extract():
    import torch
    from study_action_head_v67 import extract_for_model
    check(); torch.set_num_threads(10); sets = suites()
    for arm in ('sam', 'free-v92', *ARMS):
        for seed in base.SEEDS:
            model, tokenizer = load_encoder(arm, seed)
            for name, rows in {**sets, 'training': training_rows(arm)}.items():
                path = feature_path(arm, seed, name)
                if not path.exists(): extract_for_model(model, tokenizer, rows, path)
    print('EXTRACT-DONE', flush=True)


def measured(rows, decisions, actions, name, fixed):
    if name in fixed: return v91.fixed_summary(rows, decisions, actions)
    result = v91.summary(rows, decisions, actions)
    result['errors'] = dict(Counter(e for r, d in zip(rows, decisions) if fit_scored(r) and (e := error_type(r, d, actions))))
    result['perRowCorrect'] = [fit_scored(r) and error_type(r, d, actions) is None for r, d in zip(rows, decisions)] if name == 'fresh' else None
    return result


def fit_scored(row): return v91.fit_eligible(row)


def replay_mode(rows, cache, labels, head, g, tag, actions, mode):
    full = v91.full_predictions(cache, rows, labels)
    if mode == 'leaf': return v91.swift(rows, full, tag)
    heads = head_values(head, cache['features'])
    prefs = [dict.fromkeys(BRANCHES, 1.) for _ in rows] if mode == 'head' else preferences(g, inputs(v91.GATE_ARM, full, heads, cache['features'], actions))
    return v91.swift(rows, full, tag, heads, prefs)


def head_for(arm, seed, rows):
    import torch
    if arm in ARMS and ARMS[arm]['joint']:
        state = torch.load(checkpoint(arm, seed), weights_only=True)['parameters']; head = torch.nn.Linear(384, 4)
        head.load_state_dict({'weight': state['action_head.weight'], 'bias': state['action_head.bias']}); return head.eval()
    cache = torch.load(feature_path(arm, seed, 'training'), weights_only=True)
    return v91.fit_head(cache['features'], rows, v89.weights_for(rows, v89.cell_weights()), seed)


def score():
    import torch
    from run_approved_signal import verify_checkpoint
    from study_fusion_v68 import model_manifest
    check(); torch.set_num_threads(10); v91.OUT = OUT; v93.feature_path = feature_path
    actions = action_map(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))
    sets = suites(); fixed = set(FIXED()); protected = v91.protected_keys(FIXED().values()); results = {}
    (OUT / 'score-start.json').write_text(json.dumps(dict(protocolSHA256=base.sha(PROTOCOL), selectionSHA256=base.sha(OUT / 'selection.json'))) + '\n')
    for seed in base.SEEDS:
        config = json.loads((ROOT / verify_checkpoint(model_manifest(seed))['checkpoint'] / 'config.json').read_text())
        labels = [config['id2label'][str(i)] for i in range(len(config['id2label']))]
        head = torch.nn.Linear(384, 4); head.load_state_dict(torch.load(v91.V75 / f'head-{seed}-full/epoch-018.pt', weights_only=True)); head.eval()
        g = gate(v91.GATE_ARM, seed); g.load_state_dict(torch.load(v91.V75 / f'gate-{v91.GATE_ARM}-{seed}/epoch-006.pt', weights_only=True)); g.eval()
        results[f'sam+v79:{seed}'] = {n: measured(r, replay_mode(r, torch.load(feature_path('sam', seed, n), weights_only=True), labels, head, g, f'v79-{seed}-{n}', actions, 'gate36'), actions, n, fixed) for n, r in sets.items()}
        for arm in ('free-v92', *ARMS):
            rows = training_rows(arm); head = head_for(arm, seed, rows)
            g = v93.fit_full_gate(arm, seed, head, sets['union'], labels, actions, protected)
            torch.save(head.state_dict(), OUT / f'head-{arm}-{seed}.pt'); torch.save(g.state_dict(), OUT / f'gate-{arm}-{seed}.pt')
            for mode in MODES:
                results[f'{arm}/{mode}:{seed}'] = {n: measured(r, replay_mode(r, torch.load(feature_path(arm, seed, n), weights_only=True), labels, head, g, f'{arm}-{seed}-{mode}-{n}', actions, mode), actions, n, fixed) for n, r in sets.items()}
            print(arm, seed, {m: (results[f'{arm}/{m}:{seed}']['fresh']['policyActionCorrect'], serious(results[f'{arm}/{m}:{seed}']['fresh']['errors'])) for m in MODES}, flush=True)
    settings = {}
    for arm in ('free-v92', *ARMS):
        for mode in MODES:
            key = f'{arm}/{mode}'; passed = {}
            for s in base.SEEDS:
                c, r = results[f'{key}:{s}'], results[f'sam+v79:{s}']
                passed[str(s)] = qualifies(c['fresh'], r['fresh'], c, r, c['real-visible'], r['real-visible'])
            settings[key] = dict(passed=passed, qualifies=all(passed.values()), rank=rank([results[f'{key}:{s}']['fresh'] for s in base.SEEDS]))
    qualifiers = [k for k, v in settings.items() if v['qualifies']]
    (OUT / 'verdict.json').write_text(json.dumps(dict(results=results, settings=settings, best=max(qualifiers, key=lambda k: settings[k]['rank']) if qualifiers else None,
        reservedScored=False, automaticReplacement=False, releaseEligible=False), indent=1) + '\n')
    print('SCORE-DONE', qualifiers, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('smoke', 'seal', 'train', 'select', 'extract', 'score'))
    parser.add_argument('--arm', choices=tuple(ARMS)); parser.add_argument('--seed', type=int, choices=base.SEEDS)
    a = parser.parse_args()
    if a.stage == 'train': train(a.arm, a.seed)
    else: globals()[a.stage]()
