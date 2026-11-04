"""Matched old-only/enriched action heads on unchanged retained SAM features."""
import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path

from action_calibration_v66 import changes, qualify, safe
from action_head_v67 import BUSINESS, gated_predictions, per_row_loss, select_epoch, target
from approved_signal import ROOT, verify
from filter_policy import identity
from model_contract import model_actions
from prepare_action_calibration_v66 import BASE, OUT as V66
from prepare_families_v60 import read, sha, write
from run_approved_signal import verify_checkpoint
from study_action_calibration_v66 import V65, manifest, replay

OUT = ROOT / 'build/signal-action-head-v67-20261101'
PROTOCOL = ROOT / 'tools/transformer-trainer/experiments/signal-action-head-v67-protocol.json'
WEIGHTS = ROOT / 'tools/transformer-trainer/experiments/signal-language-control-v52-weights.json'
SEEDS = (321, 322)
ARMS = ('control', 'data')


def check():
    p = json.loads(PROTOCOL.read_text())
    for name, expected in p['filesSHA256'].items():
        if sha(ROOT / name) != expected: raise ValueError('frozen head study drift: ' + name)
    for seed in SEEDS: verify_checkpoint(manifest(seed))
    return p


def seal():
    if PROTOCOL.exists(): raise ValueError('head protocol already sealed')
    OUT.mkdir(exist_ok=True, parents=True)
    base = verify(BASE); admission = json.loads((V66 / 'admission.json').read_text())
    assert json.loads((V66 / 'selection.json').read_text())['selectedFloor'] is None
    assert not (V66 / 'evaluation-start.json').exists()
    old = read(ROOT / base['training']); new = read(ROOT / admission['roleFiles']['calibration'])
    assert len(old) == 3457 and len(new) == 72
    weight = json.loads(WEIGHTS.read_text()); assert weight['trainingSHA256'] == sha(ROOT / base['training'])
    assert set(weight['entries']) == {identity(r['text']) for r in old}
    # Repeat mandatory external-signature checks before exposing any head to data.
    from import_reviewed_public import keys
    protected_paths = [ROOT / 'tools/apple-trainer/Evaluation' / n for n in
        ('classification-regressions.ndjson', 'promotion-regressions.ndjson', 'billing-card-regressions.ndjson')]
    protected_paths.append(ROOT / admission['roleFiles']['development'])
    protected = {k for f in protected_paths for r in read(f) for k in keys(r['text'], family=True)}
    assert all(not (keys(r['text'], family=True) & protected) for r in old + new)
    train = OUT / 'training-pool.ndjson'
    with train.open('x') as f:
        for row in old + new: f.write(json.dumps(row, ensure_ascii=False) + '\n')
    previous = json.loads((V65 / 'protocol.json').read_text())
    deps = [BASE, WEIGHTS, train, V66 / 'admission.json', V66 / 'selection.json', V66 / 'verdict.json',
        V66 / 'runtime', V65 / 'protocol.json', V65 / 'summary.json', *protected_paths,
        ROOT / admission['roleFiles']['calibration'], *(ROOT / n for n in base['filesSHA256']),
        *(manifest(seed) for seed in SEEDS), ROOT / 'packages/taxonomy/taxonomy.json']
    for arm, cohorts in previous['cohorts'].items():
        for name, spec in cohorts.items():
            deps += [ROOT / spec['gold'], V65 / f'{arm}-{name}-transactionSum-predictions.ndjson',
                     V65 / f'{arm}-{name}-leaf-swift.ndjson']
    deps += [Path(__file__), Path(__file__).with_name('action_head_v67.py'),
        Path(__file__).with_name('tests') / 'test_action_head_v67.py',
        Path(__file__).with_name('action_calibration_v66.py'), Path(__file__).with_name('study_action_calibration_v66.py')]
    actions = model_actions(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))
    import torch
    labels = torch.tensor([target(r['label'], actions) for r in old])
    weights = torch.tensor([weight['entries'][identity(r['text'])]['weight'] for r in old], dtype=torch.float64)
    mass = torch.bincount(labels, weights=weights, minlength=4)
    class_weights = (mass.sum() / (4 * mass)).sqrt().clamp(max=3)
    class_weights /= (mass * class_weights).sum() / mass.sum()
    write(PROTOCOL, dict(name='signal-action-head-v67', createdUTC=datetime.now(timezone.utc).isoformat(),
        training=str(train.relative_to(ROOT)), oldRows=3457, addedRows=72,
        development=admission['roleFiles']['development'], seeds=list(SEEDS), arms=list(ARMS),
        epochs=18, updates=504, batchesPerEpoch=28, featureDimension=384,
        optimizer='AdamW lr1e-3, weight_decay.01, eps1e-8, betas(.9,.999); 50-step linear warmup then cosine to1e-4; gradient clip1; CPU FP32',
        classWeights=class_weights.tolist(), effectiveOldClassMass=mass.tolist(),
        objective='Four-action weighted CE; commercial accepts promotion OR harmful mass. Frozen v52 VI row weights; new72 weight1. Common sqrt-inverse old-class mass weights for both arms. Deterministic equal-sized partitions avoid singleton final batches.',
        representation='384-dimensional input to the existing fine classifier, extracted in eval mode. SAM encoder, pooling head and53-label classifier frozen. Independent zero-initialized4-way linear head; no LLRD/SAM on frozen encoder.',
        routing='Only permit existing transactionSum with floor.90 when head business probability>=.90. Otherwise existing leaf output. Head cannot directly emit spam/promotion or change raw fine labels.',
        selection='Epoch0 leaf plus18epochs on fresh72 external family development only. Candidates require action>=90%, harmful>=90%, no new correct-to-wrong action, no commercial/harmful-to-business shift, and strict gain. Rank action correct, lower unweighted development head loss, earlier epoch. No eligible checkpoint retains epoch0.',
        acceptance='Both data seeds must have selectedEpoch>0, pass four historical cohort safety vetoes and the known training-family safety check, fresh>=90% action/harmful, no normal junk/promotion. Both seeds no worse than their matched selected control; at least one strict fresh action gain for data attribution. No post-veto runner-up selection.',
        roleAmendment='V66 calibration failed before development was scored. Its72 calibration rows now become head-fitting additions. Original72 development remains the external checkpoint-selection split, not final validation.',
        runtime=str((V66 / 'runtime').relative_to(ROOT)), modelWeightsChanged=False,
        sourceIndependentFinal=False, releaseEligible=False,
        filesSHA256={str(f.relative_to(ROOT)): sha(f) for f in sorted(set(deps))}))
    print('Sealed two-seed two-arm18epoch head study; frozen SAM and unscored external72.', flush=True)


def actions(): return model_actions(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))


def extract_for_model(model, tokenizer, rows, path):
    import torch
    vectors = []; logits = []; current = []
    handle = model.classifier.register_forward_pre_hook(lambda _module, inputs: current.append(inputs[0].detach().clone()))
    try:
        with torch.inference_mode():
            for start in range(0, len(rows), 32):
                batch = rows[start:start + 32]
                tokens = tokenizer([r['text'] for r in batch], padding='max_length', truncation=True,
                                   max_length=96, return_tensors='pt')
                current.clear(); output = model(**tokens).logits
                assert len(current) == 1 and current[0].shape == (len(batch), 384)
                assert torch.equal(model.classifier(current[0]), output)
                vectors.append(current[0].clone()); logits.append(output.clone())
                if start % 512 == 0: print('features', path.stem, start, '/', len(rows), flush=True)
    finally:
        handle.remove()
    payload = dict(features=torch.cat(vectors), logits=torch.cat(logits),
                   textSHA256=[identity(r['text']) for r in rows])
    if path.exists(): raise ValueError('feature cache already exists')
    torch.save(payload, path)
    return payload


def predictions(cache, rows, seed):
    import torch
    config = json.loads((ROOT / verify_checkpoint(manifest(seed))['checkpoint'] / 'config.json').read_text())
    labels = [config['id2label'][str(i)] for i in range(len(config['id2label']))]
    assert cache['textSHA256'] == [identity(r['text']) for r in rows]
    p = cache['logits'].double().softmax(-1)
    return [dict(text=r['text'], label=r['label'], prediction=labels[int(v.argmax())], confidence=float(v.max()),
                 probabilities=dict(zip(labels, v.tolist(), strict=True))) for r, v in zip(rows, p, strict=True)]


def extract():
    import torch
    from transformers import AutoModelForSequenceClassification, AutoTokenizer
    torch.set_num_threads(2); p = check()
    for seed in SEEDS:
        cp = ROOT / verify_checkpoint(manifest(seed))['checkpoint']
        model = AutoModelForSequenceClassification.from_pretrained(cp, local_files_only=True, attn_implementation='eager').eval()
        model.requires_grad_(False); tokenizer = AutoTokenizer.from_pretrained(cp, local_files_only=True)
        for name, path in [('training', p['training']), ('development', p['development'])]:
            rows = read(ROOT / path)
            cache = extract_for_model(model, tokenizer, rows, OUT / f'{seed}-{name}-features.pt')
            if name == 'training':
                old = read(V66 / f'calibration-{seed}-full.ndjson')
                new = predictions(cache, rows, seed)[p['oldRows']:]
                assert all(a['prediction'] == b['prediction'] and abs(a['confidence'] - b['confidence']) < 1e-7
                           for a, b in zip(old, new, strict=True)), 'calibration prediction drift'
        del model
    write(OUT / 'feature-receipt.json', dict(filesSHA256={f.name: sha(f) for f in OUT.glob('*-features.pt')},
        protocolSHA256=sha(PROTOCOL), frozenClassifierLogitsReproduced=True))


def head_record(head, features, labels, rows, full, baseline, name, p):
    import torch
    with torch.no_grad():
        logits = head(features)
        loss = float(per_row_loss(logits, labels).mean())
        scores = logits.double().softmax(-1).tolist()
    gated = gated_predictions(full, scores)
    output, metric = replay(rows, gated, name, .90, p)
    return {**metric, 'comparison': changes(rows, baseline, output), 'headDevelopmentLoss': loss}, output


def fit():
    import torch
    torch.set_num_threads(2); p = check()
    receipt = json.loads((OUT / 'feature-receipt.json').read_text())
    assert receipt['protocolSHA256'] == sha(PROTOCOL)
    for name, digest in receipt['filesSHA256'].items(): assert sha(OUT / name) == digest
    rows = read(ROOT / p['training']); dev = read(ROOT / p['development'])
    labels = torch.tensor([target(r['label'], actions()) for r in rows])
    devlabels = torch.tensor([target(r['label'], actions()) for r in dev])
    spec = json.loads(WEIGHTS.read_text())['entries']
    rowweights = torch.tensor([spec[identity(r['text'])]['weight'] if i < p['oldRows'] else 1.
                              for i, r in enumerate(rows)], dtype=torch.float32)
    classweights = torch.tensor(p['classWeights'], dtype=torch.float32)
    combined = rowweights * classweights[labels]
    selections = {}
    for seed in SEEDS:
        train = torch.load(OUT / f'{seed}-training-features.pt', weights_only=True)
        valid = torch.load(OUT / f'{seed}-development-features.pt', weights_only=True)
        full = predictions(valid, dev, seed)
        baseline, base = replay(dev, full, f'{seed}-development-leaf', 'leaf', p)
        for arm in ARMS:
            directory = OUT / f'{arm}-{seed}'; directory.mkdir()
            count = p['oldRows'] if arm == 'control' else len(rows)
            x, y, weights = train['features'][:count], labels[:count], combined[:count]
            head = torch.nn.Linear(384, 4)
            torch.nn.init.zeros_(head.weight); torch.nn.init.zeros_(head.bias)
            optimizer = torch.optim.AdamW(head.parameters(), lr=1e-3, weight_decay=.01, eps=1e-8)
            records = [{**base, 'epoch': 0, 'comparison': changes(dev, baseline, baseline), 'headDevelopmentLoss': math.inf}]
            history = []; step = 0
            def objective(): return (per_row_loss(head(x), y) * weights).sum() / weights.sum()
            initial = float(objective().detach())
            for epoch in range(1, 19):
                order = torch.randperm(count, generator=torch.Generator().manual_seed(seed * 100 + epoch))
                for batch in torch.tensor_split(order, 28):
                    step += 1
                    lr = .001 * step / 50 if step <= 50 else .0001 + .0009 * .5 * (1 + math.cos(math.pi * (step - 50) / 454))
                    optimizer.param_groups[0]['lr'] = lr
                    optimizer.zero_grad(set_to_none=True)
                    loss = (per_row_loss(head(x[batch]), y[batch]) * weights[batch]).sum() / weights[batch].sum()
                    loss.backward(); torch.nn.utils.clip_grad_norm_(head.parameters(), 1.); optimizer.step()
                optimizer.zero_grad(set_to_none=True); value = objective(); value.backward()
                gradient_rms = float(torch.cat([v.grad.flatten() for v in head.parameters()]).square().mean().sqrt())
                history.append(dict(epoch=epoch, trainingLoss=float(value.detach()), gradientRMS=gradient_rms, learningRate=lr, updates=step))
                torch.save(head.state_dict(), directory / f'epoch-{epoch:03d}.pt')
                record, _ = head_record(head, valid['features'], devlabels, dev, full, baseline,
                    f'{arm}-{seed}-epoch-{epoch:03d}', p)
                records.append({**record, 'epoch': epoch})
                print(arm, seed, epoch, 'loss', history[-1]['trainingLoss'], 'action', record['policy']['actionCorrect'],
                      'introduced', record['comparison']['introduced'], 'newBusinessMiss', record['comparison']['newMissToBusiness'], flush=True)
            assert step == 504
            selected = select_epoch(records)
            diagnostic = max(records[1:], key=lambda r: (r['policy']['actionCorrect'], -r['headDevelopmentLoss'], -r['epoch']))
            # JSON must remain strict even though the leaf baseline has no head loss.
            records[0]['headDevelopmentLoss'] = None
            write(directory / 'training.json', dict(initialLoss=initial, history=history, records=records,
                selectedEpoch=selected['epoch'], diagnosticEpoch=diagnostic['epoch'], originalSAMChanged=False,
                stationarityProven=False, epochsCompleted=18))
            selections[f'{arm}-{seed}'] = dict(selectedEpoch=selected['epoch'], diagnosticEpoch=diagnostic['epoch'],
                selectedFresh=selected, trainingSHA256=sha(directory / 'training.json'))
    write(OUT / 'selection.json', dict(arms=selections, selectedUTC=datetime.now(timezone.utc).isoformat(),
                                     protocolSHA256=sha(PROTOCOL), oldCohortsScoredForSelection=False))


def evaluate():
    import torch
    from transformers import AutoModelForSequenceClassification, AutoTokenizer
    torch.set_num_threads(2); p = check(); selected = json.loads((OUT / 'selection.json').read_text())
    assert selected['protocolSHA256'] == sha(PROTOCOL)
    previous = json.loads((V65 / 'protocol.json').read_text()); results = {}
    training_rows = read(ROOT / p['training'])
    for seed in SEEDS:
        heads = {}
        for arm in ARMS:
            name = f'{arm}-{seed}'; choice = selected['arms'][name]
            assert choice['trainingSHA256'] == sha(OUT / name / 'training.json')
            epoch = choice['selectedEpoch']
            if epoch:
                head = torch.nn.Linear(384, 4)
                head.load_state_dict(torch.load(OUT / name / f'epoch-{epoch:03d}.pt', weights_only=True)); head.eval()
                heads[arm] = head
            results[name] = dict(selectedEpoch=epoch, fresh=choice['selectedFresh'], cohorts={})
        model = None
        for cohort in ['known-fit72', *previous['cohorts'][f'retained-{seed}']]:
            if cohort == 'known-fit72':
                rows = training_rows[p['oldRows']:]
                train = torch.load(OUT / f'{seed}-training-features.pt', weights_only=True)
                cache = {k: v[p['oldRows']:] for k, v in train.items()}
                full = predictions(cache, rows, seed)
                baseline, bm = replay(rows, full, f'{seed}-{cohort}-leaf', 'leaf', p)
            else:
                spec = previous['cohorts'][f'retained-{seed}'][cohort]; rows = read(ROOT / spec['gold'])
                full = read(V65 / f'retained-{seed}-{cohort}-transactionSum-predictions.ndjson')
                baseline, bm = replay(rows, full, f'{seed}-{cohort}-leaf', 'leaf', p)
                assert baseline == read(V65 / f'retained-{seed}-{cohort}-leaf-swift.ndjson'), 'default runtime drift'
                if heads:
                    if model is None:
                        cp = ROOT / verify_checkpoint(manifest(seed))['checkpoint']
                        model = AutoModelForSequenceClassification.from_pretrained(cp, local_files_only=True, attn_implementation='eager').eval()
                        model.requires_grad_(False); tokenizer = AutoTokenizer.from_pretrained(cp, local_files_only=True)
                    cache = extract_for_model(model, tokenizer, rows, OUT / f'{seed}-{cohort}-features.pt')
                    current = predictions(cache, rows, seed)
                    assert all(a['prediction'] == b['prediction'] and abs(a['confidence'] - b['confidence']) < 1e-7
                               for a, b in zip(current, full, strict=True)), 'historical classifier drift'
            for arm in ARMS:
                if arm in heads:
                    labels = torch.tensor([target(r['label'], actions()) for r in rows])
                    record, output = head_record(heads[arm], cache['features'], labels, rows, full, baseline,
                                                f'{arm}-{seed}-{cohort}', p)
                else:
                    record = {**bm, 'comparison': changes(rows, baseline, baseline)}; output = baseline
                indices = sorted(set(record['comparison']['recovered'] + record['comparison']['introduced'] + record['comparison']['newMissToBusiness']))
                results[f'{arm}-{seed}']['cohorts'][cohort] = dict(baseline=bm, candidate=record, evidence=[dict(index=i,
                    text=rows[i]['text'], label=rows[i]['label'], language=rows[i]['language'], kind=rows[i]['filterReview']['kind'],
                    prediction=full[i]['prediction'], before=baseline[i]['engineAction'], after=output[i]['engineAction']) for i in indices])
                print('veto', arm, seed, cohort, bm['policy']['actionCorrect'], record['policy']['actionCorrect'], record['comparison'], flush=True)
        del model
    individual = {}
    for name, result in results.items():
        individual[name] = result['selectedEpoch'] > 0 and qualify([result['fresh']],
            [r['candidate'] for r in result['cohorts'].values()])
    nonworse = all(results[f'data-{s}']['fresh']['policy']['actionCorrect'] >= results[f'control-{s}']['fresh']['policy']['actionCorrect'] for s in SEEDS)
    gain = any(results[f'data-{s}']['fresh']['policy']['actionCorrect'] > results[f'control-{s}']['fresh']['policy']['actionCorrect'] for s in SEEDS)
    write(OUT / 'summary.json', dict(results=results, individualQualification=individual,
        enrichedPairAccepted=all(individual[f'data-{s}'] for s in SEEDS) and nonworse and gain,
        dataHasMatchedFreshGain=nonworse and gain, sourceIndependentFinal=False, releaseEligible=False,
        originalSAMChanged=False, deployed=False, protocolSHA256=sha(PROTOCOL), selectionSHA256=sha(OUT / 'selection.json')))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('seal', 'extract', 'fit', 'evaluate'))
    globals()[parser.parse_args().phase]()
