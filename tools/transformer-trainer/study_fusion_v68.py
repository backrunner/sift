"""Cost-sensitive action heads, fixed fusion, calibration-only checkpoint selection."""
import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import shutil
import subprocess

from action_head_v67 import target
from approved_signal import ROOT
from filter_policy import identity
from fusion_v68 import loss, eligible, select
from language_control_v52 import policy_metrics
from model_contract import model_actions
from prepare_families_v60 import read, sha, write
from prepare_fusion_v68 import OUT, NAME
from run_approved_signal import verify_checkpoint
from study_action_head_v67 import extract_for_model

EXP = ROOT / 'tools/transformer-trainer/experiments'
PROTOCOL = EXP / f'{NAME}-protocol.json'
V67 = ROOT / 'build/signal-action-head-v67-20261101'
V66 = ROOT / 'build/signal-action-calibration-v66-20261101'
V65 = ROOT / 'build/signal-action-gap-v65-20261101'
SEEDS = (321, 322)
ARMS = ('standard', 'risk')


def model_manifest(seed): return EXP / f'signal-sam-retained-v33-{seed}.json'
def actions(): return model_actions(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))
def checkpoint(arm, seed, epoch):
    return (V67 / f'data-{seed}' if arm == 'standard' else OUT / f'risk-{seed}') / f'epoch-{epoch:03d}.pt'


def check():
    p = json.loads(PROTOCOL.read_text())
    for name, digest in p['filesSHA256'].items():
        if sha(ROOT / name) != digest: raise ValueError('sealed dependency drift: ' + name)
    for seed in SEEDS: verify_checkpoint(model_manifest(seed))
    return p


def seal():
    if PROTOCOL.exists(): raise ValueError('already sealed')
    admission = json.loads((OUT / 'admission.json').read_text())
    for name, digest in {**admission['sourceSHA256'], **admission['historicalFilesSHA256']}.items():
        assert sha(ROOT / name) == digest
    for role, name in admission['roleFiles'].items(): assert sha(ROOT / name) == admission['roleFilesSHA256'][role]
    assert not json.loads((OUT / 'strict-audit.json').read_text())['audit_gaps']
    previous = json.loads((EXP / 'signal-action-head-v67-protocol.json').read_text())
    receipt = json.loads((V67 / 'feature-receipt.json').read_text())
    for seed in SEEDS:
        assert sha(V67 / f'{seed}-training-features.pt') == receipt['filesSHA256'][f'{seed}-training-features.pt']
        verify_checkpoint(model_manifest(seed))
    runtime = OUT / 'runtime'; assert not runtime.exists()
    shutil.copy2(ROOT / 'apps/ios/.build/out/Products/Release/MessageFilterPredictionAudit', runtime)
    cohorts = dict(json.loads((V65 / 'protocol.json').read_text())['cohorts']['retained-321'])
    cohorts['old72'] = dict(gold='tools/transformer-trainer/Evaluation/signal-action-calibration-v66-development.ndjson')
    deps = [runtime, OUT / 'admission.json', OUT / 'strict-audit.json', ROOT / previous['training'],
        EXP / 'signal-action-head-v67-protocol.json', EXP / 'signal-language-control-v52-weights.json',
        V67 / 'feature-receipt.json', ROOT / 'packages/taxonomy/taxonomy.json',
        *(ROOT / name for name in admission['roleFiles'].values()), *(ROOT / spec['gold'] for spec in cohorts.values()),
        V65 / 'protocol.json', V65 / 'summary.json']
    for seed in SEEDS:
        deps += [model_manifest(seed), V67 / f'{seed}-training-features.pt', V67 / f'{seed}-development-features.pt',
                 V67 / f'data-{seed}/training.json']
        deps += [checkpoint('standard', seed, e) for e in range(1,19)]
        for name in cohorts:
            if name == 'old72':
                deps += [V66 / f'{seed}-development-leaf-predictions.ndjson', V66 / f'{seed}-development-leaf-swift.ndjson']
            else:
                deps += [V67 / f'diagnostic-{seed}-{name}-features.pt',
                    V65 / f'retained-{seed}-{name}-transactionSum-predictions.ndjson',
                    V65 / f'retained-{seed}-{name}-leaf-swift.ndjson']
    deps += list((ROOT / 'apps/ios/Sources/MessageFilterCore').glob('*.swift'))
    deps += [ROOT / 'apps/ios/Tools/MessageFilterPredictionAudit/main.swift',
        ROOT / 'apps/ios/Tests/MessageFilterCoreTests/TransformerActionFusionTests.swift',
        Path(__file__), Path(__file__).with_name('fusion_v68.py'), Path(__file__).with_name('action_head_v67.py'),
        Path(__file__).with_name('study_action_head_v67.py'), Path(__file__).with_name('tests') / 'test_fusion_v68.py',
        *(ROOT / name for name in admission['sourceSHA256'])]
    write(PROTOCOL, dict(name=NAME, createdUTC=datetime.now(timezone.utc).isoformat(),
        roles=admission['roleFiles'], training=previous['training'], trainingCount=3529,
        seeds=list(SEEDS), arms=list(ARMS), epochs=18, updates=504, classWeights=previous['classWeights'],
        optimizer='Same v67 AdamW1e-3, warmup50, cosine to1e-4, decay.01, clip1,28 balanced batches each epoch. Frozen encoder; no LLRD. Reuse all18 hash-pinned v67 data checkpoints as standard-loss control.',
        treatment='Only add2x negative log probability of business-or-ordinary on normal training rows. Keep commercial tolerant and harmful strict; all row weights and examples unchanged.',
        fusion='Fixed Swift policy: preserve normal fine/ordinary confidence>=.60; never downgrade existing junk; upgrade promotion only with head harmful>=.98; head commercial>=.98 can resolve remaining uncertainty; business head>=.90 plus fine business mass>=.60 can rescue uncertain leaves with actual fine confidence and protected subactions.',
        selection='New calibration72 only. Epoch0 originalSAM plus18 head checkpoints. Every language: no normal junk/promotion increase, no harmful/commercial recall loss. Overall zero normal filters, >=90% action and harmful recall, no fine-protection or junk-downgrade violation; strict action or harmful gain. Rank harmful count, action correct, earlier epoch. Both seeds eligible to propose a pair; rank minimum harmful, total harmful, minimum action, total action; exact ties prefer risk arm.',
        validation='One fixed preferred pair, no runner-up adoption after validation. Also show the matched control if calibration-qualified. New validation72 same fresh gates. Five spent cohorts: no normal junk/promotion increase, <=2normal junk, no per-language harmful/commercial loss, <=0.5 percentage-point action drop, no protected fine change or junk downgrade. No final real-world/release claim.',
        runtime=str(runtime.relative_to(ROOT)), cohorts=cohorts, newTrainingRows=0,
        modelEncoderChanged=False, sourceIndependentFinal=False, releaseEligible=False,
        filesSHA256={str(f.relative_to(ROOT)): sha(f) for f in sorted(set(deps))}))
    print('Sealed v68: fixed fusion and one cost change; new72 calibration plus new72 validation.', flush=True)


def raw_predictions(cache, rows, seed):
    config = json.loads((ROOT / verify_checkpoint(model_manifest(seed))['checkpoint'] / 'config.json').read_text())
    labels = [config['id2label'][str(i)] for i in range(len(config['id2label']))]
    assert cache['textSHA256'] == [identity(r['text']) for r in rows]
    return [dict(text=r['text'], label=r['label'], prediction=labels[int(v.argmax())], confidence=float(v.max()),
        probabilities=dict(zip(labels, v.tolist(), strict=True)))
        for r, v in zip(rows, cache['logits'].double().softmax(-1), strict=True)]


def new_features(seed, role, p):
    from transformers import AutoModelForSequenceClassification, AutoTokenizer
    cp = ROOT / verify_checkpoint(model_manifest(seed))['checkpoint']
    model = AutoModelForSequenceClassification.from_pretrained(cp, local_files_only=True, attn_implementation='eager').eval()
    model.requires_grad_(False); tokenizer = AutoTokenizer.from_pretrained(cp, local_files_only=True)
    rows = read(ROOT / p['roles'][role])
    cache = extract_for_model(model, tokenizer, rows, OUT / f'{seed}-{role}-features.pt')
    return rows, cache, raw_predictions(cache, rows, seed)


def replay(rows, full, name, p, head=None, features=None, baseline=None):
    import torch
    if head is None:
        inputs = [{k:v for k,v in r.items() if k != 'probabilities'} for r in full]
    else:
        with torch.no_grad(): values = head(features).double().softmax(-1).tolist()
        inputs = [{**r, 'actionProbabilities':dict(zip(('business','ordinary','commercial','harmful'),v,strict=True))}
                  for r,v in zip(full,values,strict=True)]
    source = OUT / f'{name}-predictions.ndjson'; output = OUT / f'{name}-swift.ndjson'
    with source.open('x') as f:
        for r in inputs: f.write(json.dumps(r,ensure_ascii=False)+'\n')
    command = [str(ROOT / p['runtime']),str(source),str(output)] + (['--action-fusion'] if head is not None else [])
    run = subprocess.run(command,capture_output=True,text=True)
    if run.returncode: raise RuntimeError(run.stderr[-4000:])
    decisions = read(output); a=actions()
    for i,(r,x,d) in enumerate(zip(rows,full,decisions,strict=True)):
        assert r['text']==x['text'] and r['label']==x['label']==d['label']
        assert d['index']==i and d['rawPrediction']==x['prediction'] and d['confidence']==x['confidence']
        assert d['fallbackReason']=='none' and d['expectedAction']==a[r['label']]
    metric=policy_metrics(rows,[{**x,**d} for x,d in zip(full,decisions,strict=True)],a)
    metric.update(inputSHA256=sha(source),outputSHA256=sha(output),protectedFineChanges=0,junkDowngrades=0)
    if baseline is not None:
        for x,b,d in zip(full,baseline,decisions,strict=True):
            if x['confidence']>=.60 and a[x['prediction']] in ('none','transaction'):
                metric['protectedFineChanges']+=any(b[k]!=d[k] for k in ('engineLabel','engineAction','engineSubAction'))
            metric['junkDowngrades']+=b['engineAction']=='junk' and d['engineAction']!='junk'
    return decisions,metric


def fit():
    import torch
    torch.set_num_threads(2);p=check();rows=read(ROOT/p['training']);a=actions()
    spec=json.loads((EXP/'signal-language-control-v52-weights.json').read_text())['entries']
    y=torch.tensor([target(r['label'],a) for r in rows])
    w=torch.tensor([spec[identity(r['text'])]['weight'] if i<3457 else 1. for i,r in enumerate(rows)])
    w*=torch.tensor(p['classWeights'])[y]
    for seed in SEEDS:
        x=torch.load(V67/f'{seed}-training-features.pt',weights_only=True)['features']
        head=torch.nn.Linear(384,4);torch.nn.init.zeros_(head.weight);torch.nn.init.zeros_(head.bias)
        opt=torch.optim.AdamW(head.parameters(),lr=.001,weight_decay=.01,eps=1e-8)
        directory=OUT/f'risk-{seed}';directory.mkdir();history=[];step=0
        def objective():return (loss(head(x),y)*w).sum()/w.sum()
        initial=float(objective().detach())
        for epoch in range(1,19):
            order=torch.randperm(len(rows),generator=torch.Generator().manual_seed(seed*100+epoch))
            for batch in torch.tensor_split(order,28):
                step+=1; lr=.001*step/50 if step<=50 else .0001+.0009*.5*(1+math.cos(math.pi*(step-50)/454))
                opt.param_groups[0]['lr']=lr;opt.zero_grad(set_to_none=True)
                value=(loss(head(x[batch]),y[batch])*w[batch]).sum()/w[batch].sum()
                value.backward();torch.nn.utils.clip_grad_norm_(head.parameters(),1.);opt.step()
            opt.zero_grad(set_to_none=True);value=objective();value.backward()
            rms=float(torch.cat([v.grad.flatten() for v in head.parameters()]).square().mean().sqrt())
            history.append(dict(epoch=epoch,trainingLoss=float(value.detach()),gradientRMS=rms,learningRate=lr,updates=step))
            torch.save(head.state_dict(),checkpoint('risk',seed,epoch))
            print('risk',seed,epoch,history[-1],flush=True)
        write(directory/'training.json',dict(initialLoss=initial,history=history,epochsCompleted=18,updatesCompleted=step,
            stationarityProven=False,headParameters=1540,originalSAMChanged=False))
    write(OUT/'fit-receipt.json',dict(protocolSHA256=sha(PROTOCOL),
        filesSHA256={str(f.relative_to(ROOT)):sha(f) for f in OUT.glob('risk-*/*')}))


def calibrate():
    import torch
    torch.set_num_threads(2);p=check();receipt=json.loads((OUT/'fit-receipt.json').read_text())
    assert receipt['protocolSHA256']==sha(PROTOCOL)
    for n,h in receipt['filesSHA256'].items():assert sha(ROOT/n)==h
    results={}
    for seed in SEEDS:
        rows,cache,full=new_features(seed,'calibration',p)
        base,bm=replay(rows,full,f'calibration-{seed}-leaf',p)
        for arm in ARMS:
            records=[{**bm,'epoch':0}]
            for epoch in range(1,19):
                head=torch.nn.Linear(384,4);head.load_state_dict(torch.load(checkpoint(arm,seed,epoch),weights_only=True));head.eval()
                output,metric=replay(rows,full,f'calibration-{arm}-{seed}-{epoch:03d}',p,head,cache['features'],base)
                records.append({**metric,'epoch':epoch})
                m=metric['policy'];print('calibration',arm,seed,epoch,m['actionCorrect'],m['normalToJunk'],m['normalToPromotion'],m['harmfulCaught'],eligible(metric,bm),flush=True)
            chosen=select(records)
            diagnostic=max(records[1:],key=lambda r:(r['policy']['actionCorrect'],r['policy']['harmfulCaught'],-r['epoch']))
            results[f'{arm}-{seed}']=dict(selected=chosen,diagnosticEpoch=diagnostic['epoch'],records=records)
    feasible=[arm for arm in ARMS if all(results[f'{arm}-{s}']['selected']['epoch']>0 for s in SEEDS)]
    def rank(arm):
        metrics=[results[f'{arm}-{s}']['selected']['policy'] for s in SEEDS]
        return (min(m['harmfulCaught'] for m in metrics),sum(m['harmfulCaught'] for m in metrics),
                min(m['actionCorrect'] for m in metrics),sum(m['actionCorrect'] for m in metrics),arm=='risk')
    preferred=max(feasible,key=rank) if feasible else None
    write(OUT/'selection.json',dict(results=results,preferredArm=preferred,feasibleArms=feasible,
        selectedUTC=datetime.now(timezone.utc).isoformat(),protocolSHA256=sha(PROTOCOL),validationScored=False,
        selectedCheckpointSHA256={f'{arm}-{s}':sha(checkpoint(arm,s,results[f'{arm}-{s}']['selected']['epoch'])) for arm in feasible for s in SEEDS}))
    print('Preferred pair fixed before validation:',preferred,flush=True)


def validate():
    import torch
    torch.set_num_threads(2);p=check();s=json.loads((OUT/'selection.json').read_text())
    assert s['protocolSHA256']==sha(PROTOCOL)
    if s['preferredArm'] is None:
        write(OUT/'verdict.json',dict(accepted=False,reason='No calibration-qualified pair; new validation72 remains unscored.',
                                     validationScored=False,releaseEligible=False));return
    write(OUT/'validation-start.json',dict(selectionSHA256=sha(OUT/'selection.json'),preferredArm=s['preferredArm'],
        startedUTC=datetime.now(timezone.utc).isoformat()))
    result={}; gates={}
    for seed in SEEDS:
        heads={}
        for arm in s['feasibleArms']:
            e=s['results'][f'{arm}-{seed}']['selected']['epoch'];cp=checkpoint(arm,seed,e)
            assert sha(cp)==s['selectedCheckpointSHA256'][f'{arm}-{seed}']
            head=torch.nn.Linear(384,4);head.load_state_dict(torch.load(cp,weights_only=True));heads[arm]=head.eval()
            result[f'{arm}-{seed}']={};gates[f'{arm}-{seed}']=True
        fresh_rows,fresh_cache,fresh_full=new_features(seed,'validation',p)
        for name in ['newValidation72',*p['cohorts']]:
            if name=='newValidation72':rows,cache,full=fresh_rows,fresh_cache,fresh_full
            elif name=='old72':
                rows=read(ROOT/p['cohorts'][name]['gold']);cache=torch.load(V67/f'{seed}-development-features.pt',weights_only=True)
                full=raw_predictions(cache,rows,seed)
            else:
                rows=read(ROOT/p['cohorts'][name]['gold']);cache=torch.load(V67/f'diagnostic-{seed}-{name}-features.pt',weights_only=True)
                assert cache['textSHA256']==[identity(r['text']) for r in rows]
                full=read(V65/f'retained-{seed}-{name}-transactionSum-predictions.ndjson')
            base,bm=replay(rows,full,f'validation-{seed}-{name}-leaf',p)
            if name!='newValidation72':
                previous=read(V66/f'{seed}-development-leaf-swift.ndjson') if name=='old72' else read(V65/f'retained-{seed}-{name}-leaf-swift.ndjson')
                assert base==previous,'default path changed'
            for arm,head in heads.items():
                output,metric=replay(rows,full,f'validation-{arm}-{seed}-{name}',p,head,cache['features'],base)
                passed=eligible(metric,bm,fresh=name=='newValidation72');gates[f'{arm}-{seed}']&=passed
                evidence=[]
                for i,(r,b,d) in enumerate(zip(rows,base,output,strict=True)):
                    if any(b[k]!=d[k] for k in ('engineAction','engineLabel','engineSubAction')):
                        evidence.append(dict(index=i,text=r['text'],kind=r['filterReview']['kind'],label=r['label'],language=r['language'],
                            originalFine=full[i]['prediction'],fineConfidence=full[i]['confidence'],before=b,after=d))
                result[f'{arm}-{seed}'][name]=dict(baseline=bm,candidate=metric,passed=passed,changes=evidence)
                m=metric['policy'];print('validation',arm,seed,name,m['actionCorrect'],m['normalToJunk'],m['normalToPromotion'],m['harmfulCaught'],passed,flush=True)
    accepted=all(gates[f'{s["preferredArm"]}-{seed}'] for seed in SEEDS)
    write(OUT/'summary.json',dict(results=result,gates=gates,preferredArm=s['preferredArm'],localQualificationPassed=accepted,
        noRunnerUpSelected=True,originalSAMChanged=False,defaultEnabled=False,adopted=False,releaseEligible=False,
        sourceIndependentFinal=False,selectionSHA256=sha(OUT/'selection.json'),protocolSHA256=sha(PROTOCOL)))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase',choices=('seal','fit','calibrate','validate'))
    globals()[parser.parse_args().phase]()
