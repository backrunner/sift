"""Seal, calibrate, then evaluate once; no gradient updates or adaptive retuning."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess

from action_calibration_v66 import FLOORS, SEEDS, changes, qualify, select_floor
from approved_signal import ROOT, verify
from language_control_v52 import policy_metrics
from model_contract import model_actions
from prepare_action_calibration_v66 import BASE, EVAL, NAME, OUT
from prepare_families_v60 import read, sha, write
from run_approved_signal import verify_checkpoint

EXP = ROOT / 'tools/transformer-trainer/experiments'
PROTOCOL = EXP / f'{NAME}-protocol.json'
V65 = ROOT / 'build/signal-action-gap-v65-20261101'


def manifest(seed): return EXP / f'signal-sam-retained-v33-{seed}.json'
def now(): return datetime.now(timezone.utc).isoformat()


def check():
    p = json.loads(PROTOCOL.read_text())
    for name, expected in p['filesSHA256'].items():
        if sha(ROOT / name) != expected: raise ValueError('sealed input drift: ' + name)
    if p['floors'] != list(FLOORS) or p['seeds'] != list(SEEDS): raise ValueError('grid/seed drift')
    for seed in SEEDS: verify_checkpoint(manifest(seed))
    return p


def seal():
    if PROTOCOL.exists(): raise ValueError('already sealed')
    admission = json.loads((OUT / 'admission.json').read_text())
    for name, expected in {**admission['filesSHA256'], **admission['historicalFilesSHA256']}.items():
        assert sha(ROOT / name) == expected, name
    for role, name in admission['roleFiles'].items():
        assert sha(ROOT / name) == admission['roleFilesSHA256'][role]
    assert not json.loads((OUT / 'strict-audit.json').read_text())['audit_gaps']
    verify(BASE)
    runtime = OUT / 'runtime'
    if runtime.exists(): raise ValueError('runtime already copied')
    shutil.copy2(ROOT / 'apps/ios/.build/out/Products/Release/MessageFilterPredictionAudit', runtime)
    previous = json.loads((V65 / 'protocol.json').read_text())
    old_files = [V65 / 'protocol.json', V65 / 'summary.json']
    for arm, cohorts in previous['cohorts'].items():
        for name, spec in cohorts.items():
            old_files.extend([ROOT / spec['gold'], V65 / f'{arm}-{name}-transactionSum-predictions.ndjson',
                              V65 / f'{arm}-{name}-leaf-swift.ndjson'])
    deps = [Path(__file__), runtime, OUT / 'admission.json', OUT / 'strict-audit.json',
        ROOT / 'packages/taxonomy/taxonomy.json', *(ROOT / p for p in admission['filesSHA256']),
        *(ROOT / p for p in admission['roleFiles'].values()), *old_files,
        *(manifest(seed) for seed in SEEDS)]
    deps += list((ROOT / 'apps/ios/Sources/MessageFilterCore').glob('*.swift'))
    deps += [ROOT / 'apps/ios/Tools/MessageFilterPredictionAudit/main.swift',
        ROOT / 'apps/ios/Tests/MessageFilterCoreTests/TransactionConfidenceTests.swift',
        Path(__file__).with_name('tests') / 'test_action_calibration_v66.py',
        Path(__file__).with_name('filter_policy.py'), Path(__file__).with_name('model_contract.py'),
        Path(__file__).with_name('language_control_v52.py')]
    write(PROTOCOL, dict(name=NAME, createdUTC=now(), floors=list(FLOORS), seeds=list(SEEDS),
        roles=admission['roleFiles'], runtime=str(runtime.relative_to(ROOT)),
        selection='Only fresh72 calibration. Shared floor across seeds. No new correct-to-wrong action or commercial/harmful-to-business shift; strict action gain. Rank weaker-seed correct count, pair correct count, then highest mass. No eligible option keeps leaf.',
        qualification='Selected floor only on fresh72 and four spent historical cohorts. No new action error or commercial/harmful-to-business shift. Fresh72 each seed >=90% action, >=90% harmful recall, zero normal junk/promotion. One-shot veto; never choose runner-up from development/history.',
        controls=['leaf', 'existing transactionSum'],
        scope='72 synthetic calibration rows and72 synthetic development rows,6 families each; not native-reviewed real-world final. No training, temperature scaling, probability alteration, model replacement or default runtime enablement.',
        modelWeightsChanged=False, releaseEligible=False,
        filesSHA256={str(p.relative_to(ROOT)): sha(p) for p in sorted(set(deps))}))
    print('Sealed fixed grid and safety veto before inference.', flush=True)


def actions(): return model_actions(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))


def infer(seed, role, protocol):
    import torch
    from transformers import AutoModelForSequenceClassification, AutoTokenizer
    torch.set_num_threads(2)
    model_spec = verify_checkpoint(manifest(seed)); cp = ROOT / model_spec['checkpoint']
    model = AutoModelForSequenceClassification.from_pretrained(cp, local_files_only=True, attn_implementation='eager').eval()
    tokenizer = AutoTokenizer.from_pretrained(cp, local_files_only=True)
    labels = [model.config.id2label[i] for i in range(model.config.num_labels)]
    rows = read(ROOT / protocol['roles'][role]); full = []
    with torch.inference_mode():
        for start in range(0, len(rows), 32):
            batch = rows[start:start + 32]
            tokens = tokenizer([r['text'] for r in batch], padding='max_length', truncation=True,
                               max_length=96, return_tensors='pt')
            probabilities = model(**tokens).logits.double().softmax(-1)
            for r, p in zip(batch, probabilities, strict=True):
                top = int(p.argmax())
                full.append(dict(text=r['text'], label=r['label'], prediction=labels[top], confidence=float(p[top]),
                                 probabilities=dict(zip(labels, p.tolist(), strict=True))))
    path = OUT / f'{role}-{seed}-full.ndjson'
    with path.open('x') as f:
        for row in full: f.write(json.dumps(row, ensure_ascii=False) + '\n')
    return rows, full


def replay(rows, full, name, policy, protocol):
    predictions = [{k: v for k, v in p.items() if k != 'probabilities'} for p in full] if policy == 'leaf' else full
    source = OUT / f'{name}-predictions.ndjson'; target = OUT / f'{name}-swift.ndjson'
    with source.open('x') as f:
        for row in predictions: f.write(json.dumps(row, ensure_ascii=False) + '\n')
    cmd = [str(ROOT / protocol['runtime']), str(source), str(target)]
    if policy not in ('leaf', 'sum'): cmd += ['--transaction-mass-floor', str(policy)]
    subprocess.run(cmd, check=True, capture_output=True)
    output = read(target)
    # The executable validates the full distribution, highest label/confidence,
    # row membership and absence of fallback. Check the external join too.
    for i, (row, p, d) in enumerate(zip(rows, full, output, strict=True)):
        assert p['text'] == row['text'] and p['label'] == row['label']
        assert d['index'] == i and d['label'] == row['label'] and d['rawPrediction'] == p['prediction']
        assert d['confidence'] == p['confidence'] and d['fallbackReason'] == 'none'
        assert d['expectedAction'] == actions()[row['label']]
    metric = policy_metrics(rows, [{**p, **d} for p, d in zip(full, output, strict=True)], actions())
    return output, {**metric, 'inputSHA256': sha(source), 'outputSHA256': sha(target)}


def calibrate():
    p = check()
    if (OUT / 'selection.json').exists(): raise ValueError('calibration already selected')
    records = [dict(floor=f, calibration={}) for f in FLOORS]; detail = {}
    for seed in SEEDS:
        rows, full = infer(seed, 'calibration', p)
        base, baseline = replay(rows, full, f'calibration-{seed}-leaf', 'leaf', p)
        total, sum_metrics = replay(rows, full, f'calibration-{seed}-sum', 'sum', p)
        detail[str(seed)] = {'leaf': baseline, 'sum': {**sum_metrics, 'comparison': changes(rows, base, total)}, 'floors': {}}
        for record in records:
            floor = record['floor']
            output, metric = replay(rows, full, f'calibration-{seed}-floor-{floor}', floor, p)
            comparison = changes(rows, base, output)
            detail[str(seed)]['floors'][str(floor)] = {**metric, 'comparison': comparison}
            record['calibration'][str(seed)] = dict(actionCorrect=metric['policy']['actionCorrect'], scored=72, comparison=comparison)
            print('calibration', seed, floor, metric['policy']['actionCorrect'], comparison, flush=True)
    write(OUT / 'calibration.json', detail)
    selected = select_floor(records)
    write(OUT / 'selection.json', dict(selectedFloor=selected, records=records, selectedUTC=now(),
        calibrationSHA256=sha(OUT / 'calibration.json'), protocolSHA256=sha(PROTOCOL),
        developmentScoredBeforeSelection=False, retainedModelsChanged=False, releaseEligible=False))
    print('Fixed common floor:', selected, flush=True)


def evaluate():
    p = check(); selection = json.loads((OUT / 'selection.json').read_text())
    assert selection['protocolSHA256'] == sha(PROTOCOL)
    assert selection['calibrationSHA256'] == sha(OUT / 'calibration.json')
    assert selection['selectedFloor'] == select_floor(selection['records'])
    if selection['selectedFloor'] is None:
        raise ValueError('No calibration-qualified strategy. Development remains unscored.')
    floor = selection['selectedFloor']; results = {}; fresh = []; historical = []
    previous = json.loads((V65 / 'protocol.json').read_text())
    previous_metrics = json.loads((V65 / 'summary.json').read_text())
    write(OUT / 'evaluation-start.json', dict(startedUTC=now(), selectionSHA256=sha(OUT / 'selection.json'), floor=floor))
    for seed in SEEDS:
        arm = f'retained-{seed}'; results[arm] = {}
        rows, full = infer(seed, 'development', p)
        for name in ['fresh72', *previous['cohorts'][arm]]:
            if name != 'fresh72':
                spec = previous['cohorts'][arm][name]
                rows = read(ROOT / spec['gold'])
                full = read(V65 / f'{arm}-{name}-transactionSum-predictions.ndjson')
            base, bm = replay(rows, full, f'{arm}-{name}-leaf', 'leaf', p)
            output, metric = replay(rows, full, f'{arm}-{name}-qualified', floor, p)
            if name != 'fresh72':
                assert base == read(V65 / f'{arm}-{name}-leaf-swift.ndjson'), 'default runtime drift'
                assert bm['policy'] == previous_metrics['results'][arm][name]['policies']['leaf']['policy']
            comparison = changes(rows, base, output)
            record = {**metric, 'comparison': comparison}
            (fresh if name == 'fresh72' else historical).append(record)
            indices = sorted(set(comparison['recovered'] + comparison['introduced'] + comparison['newMissToBusiness']))
            errors = [dict(index=i, text=rows[i]['text'], label=rows[i]['label'], language=rows[i]['language'],
                           kind=rows[i]['filterReview']['kind'], prediction=full[i]['prediction'],
                           confidence=full[i]['confidence'], before=base[i]['engineAction'], after=output[i]['engineAction'],
                           transactionConfidence=output[i].get('transactionConfidence')) for i in indices]
            results[arm][name] = dict(baseline=bm, candidate=record, changes=errors)
            print('validation', arm, name, bm['policy']['actionCorrect'], metric['policy']['actionCorrect'], comparison, flush=True)
    passed = qualify(fresh, historical)
    write(OUT / 'summary.json', dict(results=results, selectedFloor=floor, localQualificationPassed=passed,
        calibrationSelectionSHA256=sha(OUT / 'selection.json'), protocolSHA256=sha(PROTOCOL),
        existingLeafOutputsReproduced=True, defaultPolicyEnabled=False, adopted=False,
        sourceIndependentFinal=False, releaseEligible=False))
    print('One-shot local qualification:', passed, 'Default remains leaf.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('seal', 'calibrate', 'evaluate'))
    globals()[parser.parse_args().phase]()
