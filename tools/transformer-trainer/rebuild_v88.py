"""Rebuild study: can a less constrained encoder beat retained SAM on approved data?

V36-v63 continuations held SAM inside a trust region (last two layers, KD .9,
L2-SP .1); v56/v57 cold starts trained only two layers. V88 removes those limits
on the unchanged reviewed pool. It never loads retired bodies or reserved
predictions, and it cannot install, export or replace a model.

Stages run in order: probe, seal, warm, train --arm A --seed S, select, verdict.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

from balanced_accumulation_v54 import window_plan
from evaluation_audit_v86 import action_map, score
from filter_policy import PROMOTION_LABELS, marginal_commercial_loss
from training_optimization import parameter_groups

ROOT = Path(__file__).resolve().parents[2]
NAME = 'signal-rebuild-v88'
OUT = ROOT / 'build/signal-rebuild-v88-20261103'
STORAGE = Path.home() / 'Library/Caches/SiftTraining' / OUT.name
PROTOCOL = ROOT / 'tools/transformer-trainer/experiments' / (NAME + '-protocol.json')
TRAINING = 'build/signal-fine-v85-20261103/training-quality-next.ndjson'
WEIGHTS = 'build/signal-balance-v87-20261103/weights.json'
RUNTIME = 'build/signal-accuracy-v79-20261102/runtime'
PRETRAINED = 'build/signal-capacity-v56-20261101/initial-12/checkpoint'
SIMILARITY = 'build/signal-rebuild-v88-20261103/history-lineage-similarity.json'
SELECTION = {'old493': 'tools/transformer-trainer/Evaluation/signal-language-quality-v50-development.ndjson',
             'dev636': 'build/signal-fine-v81-20261102/development.ndjson'}
HISTORY = 'tools/transformer-trainer/Evaluation/signal-language-quality-v50-regression.ndjson'
ISOLATION = ['tools/apple-trainer/Evaluation/classification-regressions.ndjson',
             'tools/apple-trainer/Evaluation/billing-card-regressions.ndjson',
             'tools/apple-trainer/Evaluation/promotion-regressions.ndjson',
             'build/signal-fine-v81-20261102/reserved.ndjson']
SAM = {321: 'build/signal-sam-retained-v33-20261029/sam-321/checkpoint',
       322: 'build/signal-sam-retained-v33-20261029/sam-322/checkpoint'}
SEEDS = (321, 322)
LOW_SIMILARITY = .3
# V57 warmed 500 steps to 3454/3457 (loss .0059), leaving its encoder almost no data
# gradient. Fifty steps still break promotion symmetry and leave real signal.
WARM_STEPS = 50
ARMS = {'cold-last2': dict(init='warmed', layers=2, lr=2e-5),
        'cold-full': dict(init='warmed', layers=12, lr=2e-5),
        'warm-free': dict(init='sam', layers=12, lr=1e-5)}
COMMON = dict(epochs=24, batch=32, accumulation=4, maxLength=96, headMultiplier=2, layerDecay=.9,
              weightDecay=.01, warmupRatio=.08, clip=1., dropout=.05, threads=3, device='cpu',
              attention='eager', knowledgeDistillation=False, parameterAnchor=False, sharpnessAware=False)


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''): digest.update(chunk)
    return digest.hexdigest()


def read(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def text_id(text): return hashlib.sha256(text.encode()).hexdigest()


def signature(text): return re.sub(r'\d+', '0', text.strip().lower())


def overlap(training, others):
    known = {signature(r['text']) for r in training}
    return {name: sum(signature(r['text']) in known for r in rows) for name, rows in others.items()}


def rank_key(record):
    """Overall final-action objective (v79), then fine label, safety, earliest."""
    return (-record['policyActionCorrect'], -record['fineCorrect'], record['normalToJunk'], record['epoch'])


def select_epoch(records):
    return min(records, key=rank_key)


def commercial_objective(logits, labels, label_to_id):
    import torch
    ids = torch.tensor([label_to_id[x] for x in PROMOTION_LABELS], device=labels.device)
    tolerant = torch.isin(labels, ids)
    return torch.where(tolerant, marginal_commercial_loss(logits, label_to_id),
                       torch.nn.functional.cross_entropy(logits, labels, reduction='none'))


def apply_trainable(model, layers):
    from train_mmbert import train_last_encoder_layers
    train_last_encoder_layers(model, layers)
    # ModernBERT embeddings stay frozen: they carry the W4 mapping on device.
    assert not any(p.requires_grad for n, p in model.named_parameters() if n.startswith('model.embeddings'))
    return [n for n, p in model.named_parameters() if p.requires_grad]


def lr_at(step, total, warmup):
    return (step + 1) / max(1, warmup) if step < warmup else max(0., (total - step) / max(1, total - warmup))


def load_model(path, dropout=0.):
    from transformers import AutoModelForSequenceClassification
    return AutoModelForSequenceClassification.from_pretrained(
        path, local_files_only=True, attn_implementation='eager', attention_dropout=dropout,
        embedding_dropout=dropout, mlp_dropout=dropout, classifier_dropout=dropout)


def predict(model, tokenizer, rows):
    import torch
    labels = [model.config.id2label[i] for i in range(model.config.num_labels)]
    result = []; model.eval()
    with torch.inference_mode():
        for start in range(0, len(rows), 32):
            batch = rows[start:start + 32]
            tokens = tokenizer([r['text'] for r in batch], padding='max_length', truncation=True,
                               max_length=COMMON['maxLength'], return_tensors='pt')
            for row, p in zip(batch, model(**tokens).logits.double().softmax(-1)):
                i = int(p.argmax())
                result.append({'text': row['text'], 'label': row['label'], 'prediction': labels[i], 'confidence': float(p[i])})
    return result


def dump(path, rows):
    Path(path).write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in rows))


def replay(rows, predictions, prefix):
    """Score through the frozen native runtime; returns independent audit metrics."""
    source, target = Path(f'{prefix}-predictions.ndjson'), Path(f'{prefix}-swift.ndjson')
    if not source.exists(): dump(source, predictions)
    subprocess.run([str(ROOT / RUNTIME), str(source), str(target)], check=True, capture_output=True, text=True)
    decisions = read(target)
    for row, pred, d in zip(rows, predictions, decisions, strict=True):
        assert row['label'] == pred['label'] == d['label'] and d['rawPrediction'] == pred['prediction']
    return decisions, score(rows, decisions, action_map(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text())))


def summarize(metric, decisions, rows):
    raw = sum(d['rawPrediction'] == r['label'] for d, r in zip(decisions, rows))
    return {k: metric[k] for k in metric if isinstance(metric[k], (int, float))} | {'rawFineCorrect': raw, 'rows': len(rows)}


def check():
    protocol = json.loads(PROTOCOL.read_text())
    for path, digest in protocol['filesSHA256'].items():
        if sha(ROOT / path) != digest: raise ValueError('sealed dependency drift: ' + path)
    return protocol


def training_inputs():
    rows = read(ROOT / TRAINING); spec = json.loads((ROOT / WEIGHTS).read_text())
    assert spec['textSHA256'] == [text_id(r['text']) for r in rows]
    return rows, spec['legacy']


def initial_path(arm, seed):
    return ROOT / SAM[seed] if ARMS[arm]['init'] == 'sam' else STORAGE / 'warmed-12'


def fit(arm, seed, out, epochs, max_updates=None, evaluate=True):
    import torch
    from transformers import AutoTokenizer
    torch.set_num_threads(COMMON['threads']); torch.manual_seed(seed)
    rows, weights = training_inputs(); initial = initial_path(arm, seed)
    tokenizer = AutoTokenizer.from_pretrained(initial, local_files_only=True)
    model = load_model(initial, COMMON['dropout']); label_to_id = dict(model.config.label2id)
    names = apply_trainable(model, ARMS[arm]['layers'])
    groups, report = parameter_groups(model, ARMS[arm]['lr'], COMMON['weightDecay'], policy='grouped',
        head_multiplier=COMMON['headMultiplier'], layer_decay=COMMON['layerDecay'])
    optimizer = torch.optim.AdamW(groups); base = [g['lr'] for g in groups]
    plan = window_plan(len(rows), COMMON['batch'], COMMON['accumulation'])
    total = plan['updatesPerEpoch'] * epochs; warmup = int(total * COMMON['warmupRatio'])
    cohorts = {k: read(ROOT / p) for k, p in SELECTION.items()}
    out.mkdir(parents=True, exist_ok=True); step = 0; log = []
    y = torch.tensor([label_to_id[r['label']] for r in rows]); w = torch.tensor(weights, dtype=torch.float32)
    if evaluate:
        for name, cohort in cohorts.items():
            dump(out / f'epoch-000-{name}-predictions.ndjson', predict(model, tokenizer, cohort))
    for epoch in range(1, epochs + 1):
        started = time.monotonic(); model.train()
        order = torch.randperm(len(rows), generator=torch.Generator().manual_seed(seed * 1000 + epoch)).tolist()
        offset = 0; total_loss = total_weight = clipped = 0.; updates = 0
        for window in plan['windowRows']:
            members = order[offset:offset + window]; offset += window
            optimizer.zero_grad(set_to_none=True); window_weight = w[members].sum()
            for part in torch.tensor(members).tensor_split(COMMON['accumulation']):
                tokens = tokenizer([rows[i]['text'] for i in part.tolist()], padding='longest', truncation=True,
                                   max_length=COMMON['maxLength'], return_tensors='pt')
                loss = (commercial_objective(model(**tokens).logits, y[part], label_to_id) * w[part]).sum() / window_weight
                loss.backward(); total_loss += float(loss.detach()) * float(window_weight)
            total_weight += float(window_weight)
            norm = torch.nn.utils.clip_grad_norm_([p for p in model.parameters() if p.requires_grad], COMMON['clip'])
            clipped += float(norm) > COMMON['clip']
            factor = lr_at(step, total, warmup)
            for group, rate in zip(optimizer.param_groups, base): group['lr'] = rate * factor
            optimizer.step(); step += 1; updates += 1
            if max_updates and step >= max_updates: break
        record = dict(epoch=epoch, loss=total_loss / total_weight, updates=step, clippedShare=clipped / updates,
                      gradNormLast=float(norm), seconds=time.monotonic() - started)
        log.append(record); print(arm, seed, record, flush=True)
        if max_updates: return record
        state = {n: p.detach().cpu().clone() for n, p in model.named_parameters() if p.requires_grad}
        torch.save(dict(parameters=state, epoch=epoch), out / f'epoch-{epoch:03d}.pt')
        if evaluate:
            for name, cohort in cohorts.items():
                dump(out / f'epoch-{epoch:03d}-{name}-predictions.ndjson', predict(model, tokenizer, cohort))
        (out / 'training.json').write_text(json.dumps(dict(arm=arm, seed=seed, trainable=len(names),
            trainableParameters=sum(p.numel() for p in model.parameters() if p.requires_grad),
            optimizerGroups=report, plan={k: plan[k] for k in ('updatesPerEpoch', 'rows')}, history=log,
            completedUpdates=step, plannedUpdates=total, protocolSHA256=sha(PROTOCOL) if PROTOCOL.exists() else None,
            releaseEligible=False), indent=2) + '\n')


def probe():
    import shutil, tempfile
    warm()
    for arm in ARMS:
        for seed in SEEDS[:1]:
            with tempfile.TemporaryDirectory() as folder:
                print('probe', arm, fit(arm, seed, Path(folder), 1, max_updates=3, evaluate=False), flush=True)


def warm():
    """Exact-label linear head on pretrained features, using training rows only."""
    import shutil, torch
    from capacity_head_v57 import warm_linear
    from transformers import AutoTokenizer
    target = STORAGE / 'warmed-12'
    if target.exists(): return
    torch.set_num_threads(8); source = ROOT / PRETRAINED
    tokenizer = AutoTokenizer.from_pretrained(source, local_files_only=True); model = load_model(source).eval()
    rows, weights = training_inputs(); captured = []
    hook = model.classifier.register_forward_hook(lambda _m, i, _o: captured.append(i[0].detach()))
    with torch.inference_mode():
        for start in range(0, len(rows), 64):
            model(**tokenizer([r['text'] for r in rows[start:start + 64]], padding='longest', truncation=True,
                              max_length=COMMON['maxLength'], return_tensors='pt'))
    hook.remove()
    state, history = warm_linear(torch.cat(captured), torch.tensor([model.config.label2id[r['label']] for r in rows]),
                                 torch.tensor(weights), dict(model.config.label2id), steps=WARM_STEPS)
    model.classifier.load_state_dict(state); STORAGE.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(target, safe_serialization=True); tokenizer.save_pretrained(target)
    (target / 'warmup.json').write_text(json.dumps(dict(history=history, developmentUsed=False), indent=2))
    print('warmed', history[-1], flush=True)


def seal():
    if PROTOCOL.exists(): raise ValueError('protocol is sealed; use a new version')
    assert (ROOT / SIMILARITY).exists() and (STORAGE / 'warmed-12/model.safetensors').exists()
    rows, _ = training_inputs()
    others = {p: read(ROOT / p) for p in [*SELECTION.values(), HISTORY, *ISOLATION]}
    leaks = overlap(rows, others)
    if any(leaks.values()): raise ValueError(f'holdout overlap {leaks}')
    from retired_samples import RetiredSamples
    retired = RetiredSamples()
    if any(retired.reason(r) for r in rows): raise ValueError('retired sample in training pool')
    me = Path(__file__).resolve()
    files = [TRAINING, WEIGHTS, RUNTIME, SIMILARITY, HISTORY, *SELECTION.values(), *ISOLATION,
             *[SAM[s] + '/model.safetensors' for s in SEEDS], str(me.relative_to(ROOT)),
             'tools/transformer-trainer/filter_policy.py', 'tools/transformer-trainer/evaluation_audit_v86.py']
    protocol = dict(name=NAME, createdUTC=datetime.now(timezone.utc).isoformat(), arms=ARMS, common=COMMON, seeds=SEEDS,
        training=TRAINING, trainingRows=len(rows), weights='v87 legacy (v86 capped-VI) row weights', runtime=RUNTIME,
        warmedInitialSHA256=sha(STORAGE / 'warmed-12/model.safetensors'),
        selection='Per arm/seed choose epochs0..24 on spent old493+dev636 only: policy action, strict fine, fewer normal-to-junk, earliest. Freeze before history.',
        questions=['cold-full vs matched cold-last2: does unfreezing the encoder raise dev fine by >=1pp in both seeds?',
                   'warm-free vs same-seed SAM: does removing KD and L2-SP improve dev fine and action without loss on low-similarity history?',
                   'Is each arm history gap to SAM smaller on rows with r33-corpus similarity <.3?'],
        signal='Capability signal requires both seeds: selection-pool policy action >=SAM, fine >=SAM+1pp, low-similarity history policy action >=SAM-.5pp. Full history reported, not a veto. No automatic replacement.',
        dataPolicy='Approved reviewed pool only. Retired bodies never trained; retirement filter asserted at seal. Expansion arm excluded pending user decision.',
        isolationOverlap=leaks, lowSimilarityThreshold=LOW_SIMILARITY, warmSteps=WARM_STEPS, warmReason='V57 500-step warmup fit training to 3454/3457 before encoder tuning; objective then did not fall. Step chosen from training-only history before any v88 evaluation.',
        reservedScored=False, newIndependentFinal=False,
        releaseEligible=False, filesSHA256={f: sha(ROOT / f) for f in files})
    PROTOCOL.write_text(json.dumps(protocol, ensure_ascii=False, indent=2) + '\n'); print('sealed', PROTOCOL, flush=True)


def train(arm, seed):
    check(); target = STORAGE / f'{arm}-{seed}'
    if target.exists(): raise ValueError('trial output exists: ' + str(target))
    fit(arm, seed, target, COMMON['epochs'])


def pooled(metrics):
    keys = ('policyActionCorrect', 'fineCorrect', 'normalToJunk', 'actionScored')
    return {k: sum(m[k] for m in metrics) for k in keys}


def select():
    check(); results = {}
    cohorts = {k: read(ROOT / p) for k, p in SELECTION.items()}
    replays = OUT / 'replays'; replays.mkdir(parents=True, exist_ok=True)
    for arm in ARMS:
        for seed in SEEDS:
            trial = STORAGE / f'{arm}-{seed}'; records = []
            for epoch in range(COMMON['epochs'] + 1):
                parts = {}
                for name, rows in cohorts.items():
                    prefix = trial / f'epoch-{epoch:03d}-{name}'; preds = read(f'{prefix}-predictions.ndjson')
                    parts[name] = replay(rows, preds, prefix)[1]
                records.append(dict(epoch=epoch, **pooled(list(parts.values())), cohorts=parts))
            chosen = select_epoch(records)
            results[f'{arm}:{seed}'] = dict(selectedEpoch=chosen['epoch'], selected=chosen, history=records)
            print(arm, seed, 'epoch', chosen['epoch'], {k: chosen[k] for k in ('policyActionCorrect', 'fineCorrect', 'normalToJunk')}, flush=True)
    (OUT / 'selection.json').write_text(json.dumps(dict(historyUsed=False, protocolSHA256=sha(PROTOCOL), results=results), indent=1) + '\n')


def checkpoint_predictions(arm, seed, epoch, rows):
    import torch
    from transformers import AutoTokenizer
    torch.set_num_threads(8); initial = initial_path(arm, seed)
    tokenizer = AutoTokenizer.from_pretrained(initial, local_files_only=True); model = load_model(initial)
    if epoch:
        state = torch.load(STORAGE / f'{arm}-{seed}/epoch-{epoch:03d}.pt', weights_only=True)['parameters']
        with torch.no_grad():
            for name, param in model.named_parameters():
                if name in state: param.copy_(state[name])
    return predict(model, tokenizer, rows)


def verdict():
    check(); selected = json.loads((OUT / 'selection.json').read_text())['results']
    history = read(ROOT / HISTORY); similarity = json.loads((ROOT / SIMILARITY).read_text())['similarity']
    low = [similarity[text_id(r['text'])] < LOW_SIMILARITY for r in history]
    folder = OUT / 'history'; folder.mkdir(exist_ok=False)
    cohorts = {k: read(ROOT / p) for k, p in SELECTION.items()}; out = {}
    def history_score(name, preds):
        decisions, metric = replay(history, preds, folder / name)
        rows_low = [r for r, x in zip(history, low) if x]; d_low = [d for d, x in zip(decisions, low) if x]
        return dict(all=metric, lowSimilarity=score(rows_low, d_low, action_map(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))))
    references = {}
    for seed in SEEDS:
        parts = {}
        for name, rows in cohorts.items():
            parts[name] = replay(rows, _sam(seed, rows), folder / f'sam-{seed}-{name}')[1]
        references[seed] = dict(selection=pooled(list(parts.values())), cohorts=parts, history=history_score(f'sam-{seed}', _sam(seed, history)))
    for key, item in selected.items():
        arm, seed = key.split(':'); seed = int(seed)
        out[key] = dict(selectedEpoch=item['selectedEpoch'], selection={k: item['selected'][k] for k in ('policyActionCorrect', 'fineCorrect', 'normalToJunk', 'actionScored')},
            cohorts=item['selected']['cohorts'], history=history_score(f'{arm}-{seed}', checkpoint_predictions(arm, seed, item['selectedEpoch'], history)))
    signals = {}
    for arm in ARMS:
        signals[arm] = all(_signal(out[f'{arm}:{s}'], references[s]) for s in SEEDS)
    (OUT / 'verdict.json').write_text(json.dumps(dict(references=references, arms=out, capabilitySignal=signals,
        reservedScored=False, automaticReplacement=False, releaseEligible=False, protocolSHA256=sha(PROTOCOL)), indent=1) + '\n')
    print('signals', signals, flush=True)


def _sam(seed, rows):
    import torch
    from transformers import AutoTokenizer
    torch.set_num_threads(8)
    return predict(load_model(ROOT / SAM[seed]), AutoTokenizer.from_pretrained(ROOT / SAM[seed], local_files_only=True), rows)


def _signal(candidate, reference):
    a, b = candidate['selection'], reference['selection']
    fine_floor = b['fineCorrect'] + .01 * b['actionScored']
    low_a, low_b = candidate['history']['lowSimilarity'], reference['history']['lowSimilarity']
    return bool(a['policyActionCorrect'] >= b['policyActionCorrect'] and a['fineCorrect'] >= fine_floor
                and low_a['policyActionCorrect'] / low_a['actionScored'] >= low_b['policyActionCorrect'] / low_b['actionScored'] - .005)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('probe', 'seal', 'warm', 'train', 'select', 'verdict'))
    parser.add_argument('--arm', choices=tuple(ARMS)); parser.add_argument('--seed', type=int, choices=SEEDS)
    a = parser.parse_args()
    if a.stage == 'train': train(a.arm, a.seed)
    else: globals()[a.stage]()
