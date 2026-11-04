"""Refit v75 directional routing on rebuilt encoders; no encoder training or install.

V75 fit its gate on post-SAM rows SAM never saw. Rebuilt encoders trained on those
rows, so here the gate fits only rows outside encoder training: family-grouped
out-of-fold over the exposed union. SAM runs the same method as a control, so any
inflation from fitting on exposed rows shows up in the control as well.

Stages run in order: seal, extract, fit, verdict.
"""
import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import subprocess

from action_head_v67 import target
from evaluation_audit_v86 import action_map, score
from expert_routing_v71 import targets
from filter_policy import identity
from harm_separation_v73 import separated_loss
from import_reviewed_public import keys
import rebuild_v88 as base
import rebuild_v89 as v89
from recovery_routing_v75 import BRANCHES, branch_indices, gate, inputs, objective, preferences
from study_action_head_v67 import extract_for_model
from study_expert_routing_v71 import head_values

ROOT = base.ROOT
NAME = 'signal-routing-v91'
OUT = ROOT / 'build/signal-routing-v91-20261104'
PROTOCOL = ROOT / 'tools/transformer-trainer/experiments' / (NAME + '-protocol.json')
CACHE = Path.home() / 'Library/Caches/SiftTraining'
V75 = ROOT / 'build/signal-recovery-v75-20261102'
V75_TRAINING = V75 / 'training-pool.ndjson'
V88_VERDICT = ROOT / 'build/signal-rebuild-v88-20261103/verdict.json'
V89_VERDICT = ROOT / 'build/signal-rebuild-v89-20261103/verdict.json'
CLASS_WEIGHTS = (0.6951120079612476, 1.1879283611262297, 1.9984456865471052, 2.2054509185418487)
SEEDS = base.SEEDS
ARMS = ('sam', 'warm-free', 'free-v89')
FOLDS = 5
HEAD_EPOCHS = 18
HEAD_BATCHES = 28
GATE_ARM = 'data-directional'
GATE_EPOCHS = 36
# V79 fixed epoch 6 before any of these encoders existed. Others are sensitivity only.
PRIMARY_GATE_EPOCH = 6
SENSITIVITY_EPOCHS = (3, 12, 24, 36)
THREADS = 10


def head_lr(step, total):
    return .001 * step / 50 if step <= 50 else .0001 + .0009 * .5 * (1 + math.cos(math.pi * (step - 50) / (total - 50)))


def gate_lr(step, total):
    return .02 * step / 16 if step <= 16 else .002 + .018 * .5 * (1 + math.cos(math.pi * (step - 16) / (total - 16)))


def family_folds(rows, count=FOLDS):
    """Rows sharing any family signature stay in one fold; deterministic by first row."""
    parent = list(range(len(rows))); owner = {}
    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]; i = parent[i]
        return i
    for i, row in enumerate(rows):
        for key in keys(row['text'], family=True):
            parent[find(i)] = find(owner.setdefault(key, i))
    groups = {}
    for i in range(len(rows)): groups.setdefault(find(i), []).append(i)
    # Largest group first onto the smallest fold keeps folds balanced.
    folds = [[] for _ in range(count)]
    for members in sorted(groups.values(), key=lambda m: (-len(m), m[0])):
        min(folds, key=len).extend(members)
    assignment = [None] * len(rows)
    for number, members in enumerate(folds):
        for i in members: assignment[i] = number
    return assignment


def fit_eligible(row):
    review = row['filterReview']
    return review['kind'] != 'unresolved' and review['inputForm'] != 'scenario-description'


def protected_keys(suites):
    return {k for rows in suites for r in rows for k in keys(r['text'], family=True)}


def fit_indices(rows, protected):
    """Hard rule 11: the union contains the fixed holdouts, which a gate must never fit."""
    return [i for i, r in enumerate(rows) if fit_eligible(r) and not keys(r['text'], family=True) & protected]


def passes(candidate, reference):
    """The sealed bar: a candidate must beat routed SAM on action without costing safety."""
    return bool(candidate['policyActionCorrect'] >= reference['policyActionCorrect']
                and candidate['harmfulCaught'] >= reference['harmfulCaught']
                and candidate['normalToJunk'] <= reference['normalToJunk'])


def union_rows():
    p = json.loads((ROOT / 'tools/transformer-trainer/experiments/signal-balance-v87-protocol.json').read_text())
    rows = {}
    for gold in [c['gold'] for c in p['cohorts'].values()] + [p['development']]:
        for row in base.read(ROOT / gold): rows.setdefault(row['text'], row)
    rows = [r for r in rows.values() if 'filterReview' in r]
    for row in rows: row['filterReview'].setdefault('fineLabelScored', True)
    return rows


def fixed_suites():
    return {n: [dict(text=r['text'], label=r['label']) for r in base.read(ROOT / f'tools/apple-trainer/Evaluation/{n}-regressions.ndjson')]
            for n in ('classification', 'promotion', 'billing-card')}


def spent_sets():
    real = ROOT / 'build/signal-real-v90-20261103'
    return {n: base.read(real / f'{f}.ndjson') for n, f in (('real-visible', 'test-real-visible'), ('official', 'test-official'))}


def training_rows(arm):
    if arm == 'sam': return base.read(V75_TRAINING)
    return base.read(ROOT / (base.TRAINING if arm == 'warm-free' else v89.ARMS[arm]['training']))


def training_weights(arm, rows):
    from study_fusion_v68 import EXP
    if arm == 'sam':
        spec = json.loads((EXP / 'signal-language-control-v52-weights.json').read_text())['entries']
        return [spec[identity(r['text'])]['weight'] if i < 3457 else 1. for i, r in enumerate(rows)]
    return v89.weights_for(rows, v89.cell_weights())


def epoch_of(arm, seed):
    if arm == 'sam': return 0
    path = V88_VERDICT if arm == 'warm-free' else V89_VERDICT
    return json.loads(path.read_text())['arms'][f'{arm}:{seed}']['selectedEpoch']


def load_encoder(arm, seed):
    import torch
    from transformers import AutoTokenizer
    path = ROOT / base.SAM[seed]; model = base.load_model(path)
    if arm != 'sam':
        study = 'signal-rebuild-v88-20261103' if arm == 'warm-free' else 'signal-rebuild-v89-20261103'
        state = torch.load(CACHE / study / f'{arm}-{seed}/epoch-{epoch_of(arm, seed):03d}.pt', weights_only=True)['parameters']
        with torch.no_grad():
            for name, value in model.named_parameters():
                if name in state: value.copy_(state[name])
    return model, AutoTokenizer.from_pretrained(path, local_files_only=True)


def seal():
    assert not PROTOCOL.exists()
    union = union_rows(); fixed = fixed_suites(); assert len(union) == 4328
    reserved = base.read(ROOT / 'build/signal-fine-v81-20261102/reserved.ndjson')
    fit_rows = [union[i] for i in fit_indices(union, protected_keys(fixed.values()))]
    union_keys = {k for r in fit_rows for k in keys(r['text'], family=True)}
    isolation = {n: sum(bool(keys(r['text'], family=True) & union_keys) for r in rows) for n, rows in {**fixed, 'reserved': reserved}.items()}
    if any(isolation.values()): raise ValueError(f'gate fit overlaps holdouts: {isolation}')
    encoder_overlap = {arm: sum(r['text'] in {x['text'] for x in union} for r in training_rows(arm)) for arm in ARMS}
    assignment = family_folds(fit_rows)
    deps = [Path(__file__), Path(__file__).with_name('tests') / 'test_routing_refit_v91.py', V88_VERDICT, V89_VERDICT, V75_TRAINING,
            ROOT / base.RUNTIME, ROOT / base.TRAINING, ROOT / v89.ARMS['free-v89']['training'], ROOT / 'packages/taxonomy/taxonomy.json',
            *[V75 / f'head-{s}-full/epoch-018.pt' for s in SEEDS], *[V75 / f'gate-{GATE_ARM}-{s}/epoch-006.pt' for s in SEEDS]]
    base.dump(OUT / 'union.ndjson', union)
    base_write(PROTOCOL, dict(
        name=NAME, createdUTC=datetime.now(timezone.utc).isoformat(), arms=list(ARMS), seeds=list(SEEDS),
        encoderEpochs={f'{a}:{s}': epoch_of(a, s) for a in ARMS for s in SEEDS},
        head=dict(fit='encoder training rows only, encoder recipe row weights times v75 class weights, separated loss', epochs=HEAD_EPOCHS, batches=HEAD_BATCHES, lr=.001, weightDecay=.01),
        gate=dict(arm=GATE_ARM, fit=f'{FOLDS} family-grouped folds on {len(fit_rows)} union rows, out of fold, excluding rows that share a family signature with the fixed holdouts; those rows are scored by a gate that never fit them', epochs=GATE_EPOCHS, batchesPerEpoch=8, primaryEpoch=PRIMARY_GATE_EPOCH, sensitivityEpochs=list(SENSITIVITY_EPOCHS)),
        comparator='Retained SAM head and gate exactly as v79 selected them, rescored here.',
        signal='A candidate passes only if, per seed, its out-of-fold routed union has policy action and harmful caught at or above SAM+v79 and normal-to-junk at or below it.',
        control='SAM refit by this same method measures how much fitting on the exposed union alone inflates a score.',
        evidenceLimit='Every scored row is exposed or spent. A pass authorizes further study only, not replacement.',
        isolation=isolation, foldSizes=[assignment.count(i) for i in range(FOLDS)], encoderTrainedOnUnionRows=encoder_overlap,
        unionSHA256=base.sha(OUT / 'union.ndjson'), reservedScored=False, releaseEligible=False,
        filesSHA256={str(p.relative_to(ROOT)): base.sha(p) for p in deps}))
    print('sealed', isolation, encoder_overlap, flush=True)


def base_write(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=1) + '\n')


def check():
    p = json.loads(PROTOCOL.read_text())
    for name, digest in p['filesSHA256'].items():
        if base.sha(ROOT / name) != digest: raise ValueError(f'changed after seal: {name}')
    return p


def feature_path(arm, seed, name): return OUT / f'features-{arm}-{seed}-{name}.pt'


def extract():
    import torch
    check(); torch.set_num_threads(THREADS)
    sets = {'union': base.read(OUT / 'union.ndjson'), **fixed_suites(), **spent_sets()}
    for arm in ARMS:
        for seed in SEEDS:
            model, tokenizer = load_encoder(arm, seed)
            for name, rows in {**sets, 'training': training_rows(arm)}.items():
                path = feature_path(arm, seed, name)
                if not path.exists(): extract_for_model(model, tokenizer, rows, path)
    print('EXTRACT-DONE', flush=True)


def fit_head(features, rows, weights, seed):
    import torch
    actions = action_map(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))
    y = torch.tensor([target(r['label'], actions) for r in rows])
    w = torch.tensor(weights, dtype=torch.float32) * torch.tensor(CLASS_WEIGHTS, dtype=torch.float32)[y]
    head = torch.nn.Linear(384, 4); torch.nn.init.zeros_(head.weight); torch.nn.init.zeros_(head.bias)
    optimizer = torch.optim.AdamW(head.parameters(), lr=.001, weight_decay=.01, eps=1e-8); step = 0
    total = HEAD_EPOCHS * HEAD_BATCHES
    for epoch in range(1, HEAD_EPOCHS + 1):
        order = torch.randperm(len(rows), generator=torch.Generator().manual_seed(seed * 100 + epoch))
        for batch in torch.tensor_split(order, HEAD_BATCHES):
            step += 1; optimizer.param_groups[0]['lr'] = head_lr(step, total); optimizer.zero_grad(set_to_none=True)
            value = (separated_loss(head(features[batch]), y[batch]) * w[batch]).sum() / w[batch].sum()
            value.backward(); torch.nn.utils.clip_grad_norm_(head.parameters(), 1.); optimizer.step()
    return head.eval()


def fit_gate(x, y, w, branches, seed, stops):
    import copy
    import torch
    g = gate(GATE_ARM, seed); optimizer = torch.optim.AdamW(g.parameters(), lr=.02, weight_decay=0, eps=1e-8)
    step = 0; total = 8 * GATE_EPOCHS; saved = {}
    for epoch in range(1, GATE_EPOCHS + 1):
        order = torch.randperm(len(x), generator=torch.Generator().manual_seed(seed * 100 + epoch))
        for batch in torch.tensor_split(order, 8):
            step += 1; optimizer.param_groups[0]['lr'] = gate_lr(step, total); optimizer.zero_grad(set_to_none=True)
            objective(g, x[batch], y[batch], w[batch], branches[batch]).backward()
            torch.nn.utils.clip_grad_norm_(g.parameters(), 1.); optimizer.step()
        if epoch in stops: saved[epoch] = copy.deepcopy(g).eval()
    return saved


def full_predictions(cache, rows, labels):
    assert cache['textSHA256'] == [identity(r['text']) for r in rows]
    p = cache['logits'].double().softmax(-1)
    return [dict(text=r['text'], label=r['label'], prediction=labels[int(v.argmax())], confidence=float(v.max()),
                 probabilities=dict(zip(labels, v.tolist(), strict=True))) for r, v in zip(rows, p, strict=True)]


def swift(rows, full, tag, heads=None, prefs=None):
    """Replay through the frozen runtime; each tag is single-use because it refuses overwrite."""
    data = [{k: v for k, v in r.items() if k != 'probabilities'} for r in full] if heads is None else \
        [dict(r, actionProbabilities=h, directionPreferences=v) for r, h, v in zip(full, heads, prefs, strict=True)]
    source, target_path = OUT / f'{tag}-predictions.ndjson', OUT / f'{tag}-swift.ndjson'
    base.dump(source, data)
    subprocess.run([str(ROOT / base.RUNTIME), str(source), str(target_path)] + ([] if heads is None else ['--directional-routing']), check=True, capture_output=True)
    decisions = base.read(target_path)
    assert all(r['label'] == d['label'] and d['fallbackReason'] == 'none' for r, d in zip(rows, decisions, strict=True))
    return decisions


KEEP = ('actionScored', 'policyActionCorrect', 'strictActionCorrect', 'nativeRouteCorrect', 'fineScored', 'fineCorrect',
        'harmful', 'harmfulCaught', 'normal', 'normalToJunk', 'commercial', 'commercialToJunk')


def summary(rows, decisions, actions):
    m = score(rows, decisions, actions); return {k: m.get(k, 0) for k in KEEP}


def fixed_summary(rows, decisions, actions):
    return dict(rows=len(rows), strictAction=sum(d['engineAction'] == actions[r['label']] for r, d in zip(rows, decisions)),
                tolerantAction=sum(d['engineAction'] == actions[r['label']] or (actions[r['label']] == 'promotion' and d['engineAction'] == 'junk') for r, d in zip(rows, decisions)),
                fine=sum(d['engineLabel'] == r['label'] for r, d in zip(rows, decisions)))


def fit():
    import torch
    check(); torch.set_num_threads(THREADS)
    from study_fusion_v68 import model_manifest
    from run_approved_signal import verify_checkpoint
    taxonomy = json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text())
    actions = action_map(taxonomy)
    union = base.read(OUT / 'union.ndjson'); fixed = fixed_suites(); spent = spent_sets()
    protected = protected_keys(fixed.values()); results = {}
    for seed in SEEDS:
        config = json.loads((ROOT / verify_checkpoint(model_manifest(seed))['checkpoint'] / 'config.json').read_text())
        labels = [config['id2label'][str(i)] for i in range(len(config['id2label']))]
        for arm in ARMS:
            key = f'{arm}:{seed}'; result = results[key] = {}
            rows = training_rows(arm)
            cache = torch.load(feature_path(arm, seed, 'training'), weights_only=True)
            head = fit_head(cache['features'], rows, training_weights(arm, rows), seed)
            torch.save(head.state_dict(), OUT / f'head-{arm}-{seed}.pt')
            union_cache = torch.load(feature_path(arm, seed, 'union'), weights_only=True)
            full = full_predictions(union_cache, union, labels)
            heads = head_values(head, union_cache['features'])
            ones = [dict.fromkeys(BRANCHES, 1.) for _ in union]
            leaf = swift(union, full, f'{arm}-{seed}-union-leaf')
            routed = swift(union, full, f'{arm}-{seed}-union-head', heads, ones)
            result['union-leaf'] = summary(union, leaf, actions); result['union-head'] = summary(union, routed, actions)
            index = fit_indices(union, protected)
            meta = [union[i] for i in index]; assignment = family_folds(meta)
            y, w = targets(meta, [leaf[i] for i in index], [routed[i] for i in index], actions)
            branches = branch_indices([routed[i] for i in index])
            x = inputs(GATE_ARM, full, heads, union_cache['features'], actions)
            stops = {PRIMARY_GATE_EPOCH, *SENSITIVITY_EPOCHS}
            prefs = {e: [dict.fromkeys(BRANCHES, 0.) for _ in union] for e in stops}
            for fold in range(FOLDS):
                train = torch.tensor([index[i] for i, f in enumerate(assignment) if f != fold])
                keep = torch.tensor([i for i, f in enumerate(assignment) if f != fold])
                held = [index[i] for i, f in enumerate(assignment) if f == fold]
                saved = fit_gate(x[train], y[keep], w[keep], branches[keep], seed, stops)
                for epoch, g in saved.items():
                    for i, value in zip(held, preferences(g, x[held]), strict=True): prefs[epoch][i] = value
            # Holdouts, unfittable rows and outside suites use the gate fit on every fit row.
            whole = fit_gate(x[index], y, w, branches, seed, stops)
            torch.save(whole[PRIMARY_GATE_EPOCH].state_dict(), OUT / f'gate-{arm}-{seed}.pt')
            fitted = set(index); outside = [i for i in range(len(union)) if i not in fitted]
            for epoch, g in whole.items():
                if outside:
                    for i, value in zip(outside, preferences(g, x[outside]), strict=True): prefs[epoch][i] = value
            for epoch in sorted(stops):
                decisions = swift(union, full, f'{arm}-{seed}-union-gate{epoch}', heads, prefs[epoch])
                result[f'union-gate{epoch}'] = summary(union, decisions, actions)
            primary = whole[PRIMARY_GATE_EPOCH]
            for name, rows2 in {**fixed, **spent}.items():
                c = torch.load(feature_path(arm, seed, name), weights_only=True)
                f2 = full_predictions(c, rows2, labels); h2 = head_values(head, c['features'])
                d2 = swift(rows2, f2, f'{arm}-{seed}-{name}-gate', h2, preferences(primary, inputs(GATE_ARM, f2, h2, c['features'], actions)))
                result[name] = fixed_summary(rows2, d2, actions) if name in fixed else summary(rows2, d2, actions)
            print(key, {k: (v.get('policyActionCorrect'), v.get('fineCorrect'), v.get('harmfulCaught'), v.get('normalToJunk')) for k, v in result.items() if k.startswith('union')}, flush=True)
        # Retained comparator: the exact heads and gates v79 selected, same replay and scorer.
        head = torch.nn.Linear(384, 4); head.load_state_dict(torch.load(V75 / f'head-{seed}-full/epoch-018.pt', weights_only=True)); head.eval()
        g = gate(GATE_ARM, seed); g.load_state_dict(torch.load(V75 / f'gate-{GATE_ARM}-{seed}/epoch-006.pt', weights_only=True)); g.eval()
        c = torch.load(feature_path('sam', seed, 'union'), weights_only=True); full = full_predictions(c, union, labels); heads = head_values(head, c['features'])
        d = swift(union, full, f'v79-{seed}-union', heads, preferences(g, inputs(GATE_ARM, full, heads, c['features'], actions)))
        result = results[f'sam+v79:{seed}'] = {'union': summary(union, d, actions)}
        for name, rows2 in {**fixed, **spent}.items():
            c = torch.load(feature_path('sam', seed, name), weights_only=True); f2 = full_predictions(c, rows2, labels); h2 = head_values(head, c['features'])
            d2 = swift(rows2, f2, f'v79-{seed}-{name}', h2, preferences(g, inputs(GATE_ARM, f2, h2, c['features'], actions)))
            result[name] = fixed_summary(rows2, d2, actions) if name in fixed else summary(rows2, d2, actions)
        base_write(OUT / 'fit.json', results)
    print('FIT-DONE', flush=True)


def verdict():
    p = check(); r = json.loads((OUT / 'fit.json').read_text()); key = f'union-gate{PRIMARY_GATE_EPOCH}'
    signals = {arm: {str(s): passes(r[f'{arm}:{s}'][key], r[f'sam+v79:{s}']['union']) for s in SEEDS} for arm in ('warm-free', 'free-v89')}
    base_write(OUT / 'verdict.json', dict(protocolSHA256=base.sha(PROTOCOL), fitSHA256=base.sha(OUT / 'fit.json'), signals=signals,
        passed={a: all(v.values()) for a, v in signals.items()}, reservedScored=False, releaseEligible=False))
    print(signals, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('stage', choices=('seal', 'extract', 'fit', 'verdict'))
    globals()[parser.parse_args().stage]()
