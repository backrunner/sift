"""Family cross-fit expert routing, with an in-sample gate as a diagnostic control."""
import argparse
from datetime import datetime,timezone
import json
import math
from pathlib import Path
import shutil
import subprocess

from approved_signal import ROOT
from action_head_v67 import target
from expert_routing_v71 import ORDER,folds,features,targets,safety,select
from filter_policy import identity
from fusion_v68 import loss
from language_control_v52 import policy_metrics
from prepare_families_v60 import read,sha,write
from prepare_routing_v71 import OUT,CALIBRATION,TRAINING
from run_approved_signal import verify_checkpoint
from study_action_head_v67 import extract_for_model
from study_fusion_v68 import actions,model_manifest,raw_predictions,V65,V66,V67,EXP

V68=ROOT/'build/signal-fusion-v68-20261102'
V69=ROOT/'build/signal-correction-v69-20261102'
V70=ROOT/'build/signal-credential-evidence-v70-20261102'
PROTOCOL=EXP/'signal-expert-routing-v71r1-protocol.json'
SEEDS=(321,322)
METHODS=('insample','crossfit')


def check():
    p=json.loads(PROTOCOL.read_text())
    for n,h in p['filesSHA256'].items():
        if sha(ROOT/n)!=h:raise ValueError('sealed dependency drift: '+n)
    for seed in SEEDS:verify_checkpoint(model_manifest(seed))
    return p


def full_head(seed,p):
    import torch
    h=torch.nn.Linear(384,4)
    h.load_state_dict(torch.load(ROOT/p['fullHeads'][str(seed)],weights_only=True))
    return h.eval()


def head_values(head,x):
    import torch
    with torch.no_grad():values=head(x).double().softmax(-1).tolist()
    return [dict(zip(ORDER,v,strict=True)) for v in values]


def seal():
    assert not PROTOCOL.exists()
    admission=json.loads((OUT/'admission.json').read_text())
    for n,h in {**admission['historicalFilesSHA256'],**admission['sourceSHA256']}.items():assert sha(ROOT/n)==h
    assert sha(CALIBRATION)==admission['calibrationSHA256']
    assert not json.loads((OUT/'strict-audit.json').read_text())['audit_gaps']
    old=json.loads((EXP/'signal-correction-v69-protocol.json').read_text())
    previous=json.loads((V70/'after-start.json').read_text())
    for n,h in previous['filesSHA256'].items():
        f=OUT/'predecessor-source/MessageFilterPredictionAudit.swift' if n=='apps/ios/Tools/MessageFilterPredictionAudit/main.swift' else ROOT/n
        assert sha(f)==h,n
    receipt=json.loads((V69/'fit-receipt.json').read_text())
    for n,h in receipt['filesSHA256'].items():assert sha(ROOT/n)==h
    selected=json.loads((V69/'selection.json').read_text())['historicalEpochs']
    full_epochs={str(seed):selected[f'data-{seed}'] for seed in SEEDS}
    full_heads={str(seed):str((V69/f'data-{seed}'/f'epoch-{full_epochs[str(seed)]:03d}.pt').relative_to(ROOT)) for seed in SEEDS}
    rows=read(TRAINING);assert len(rows)==3601
    meta=rows[3457:];split=folds(meta)
    assert len(meta)==144 and all(split.count(i)==48 for i in range(3))
    # These144 were authored after the retained SAM fitting; they entered only
    # frozen-encoder action-head fitting in v67/v69. Do not use the old3457 as gate labels.
    write(OUT/'folds.json',dict(metaOffset=3457,metaRows=144,foldAssignments=split,
        metaTextSHA256=[identity(r['text']) for r in meta],families={r['familyId']:split[i] for i,r in enumerate(meta)},
        formerV66Role='The v66 calibration72 was explicitly reassigned to head fitting in v67, before its separate development split was scored. This study uses that already-fitting subset, never v66 development or v68/v69 calibration.'))
    from import_reviewed_public import keys
    protected=[ROOT/'tools/apple-trainer/Evaluation'/n for n in
        ('classification-regressions.ndjson','promotion-regressions.ndjson','billing-card-regressions.ndjson')]
    protected+=[CALIBRATION,ROOT/old['reservedValidation'],*(ROOT/v['gold'] for v in old['cohorts'].values()),ROOT/old['roles']['calibration']]
    sig={k for f in protected for r in read(f) for k in keys(r['text'],family=True)}
    assert all(not(keys(r['text'],family=True)&sig) for r in rows)
    assert not list(V68.glob('*validation*features.pt')) and not list(V69.glob('*validation*features.pt'))
    runtime=OUT/'runtime';assert not runtime.exists()
    shutil.copy2(ROOT/'apps/ios/.build/out/Products/Release/MessageFilterPredictionAudit',runtime)
    cohorts=dict(old['cohorts']);cohorts['v69-calibration72']={'gold':old['roles']['calibration']}
    deps=[runtime,TRAINING,CALIBRATION,OUT/'admission.json',OUT/'strict-audit.json',OUT/'folds.json',
        V69/'fit-receipt.json',V69/'selection.json',V70/'after.json',V70/'after-start.json',V70/'runtime-after',
        EXP/'signal-correction-v69-protocol.json',EXP/'signal-language-control-v52-weights.json',
        *(ROOT/n for n in full_heads.values()),*protected,ROOT/'packages/taxonomy/taxonomy.json']
    for seed in SEEDS:
        deps+=[model_manifest(seed),V67/f'{seed}-training-features.pt',V69/f'{seed}-new-training-features.pt',
               V68/f'{seed}-calibration-features.pt',V69/f'{seed}-calibration-features.pt',V67/f'{seed}-development-features.pt']
        for name in cohorts:
            if name=='v69-calibration72':deps+=[V70/f'calibration-{seed}-leaf-swift.ndjson']
            else:deps+=[V70/f'history-{seed}-{name}-leaf-swift.ndjson']
            if name not in ('old72','v68-calibration72','v69-calibration72'):
                deps+=[V67/f'diagnostic-{seed}-{name}-features.pt',V65/f'retained-{seed}-{name}-transactionSum-predictions.ndjson']
    deps+=list((ROOT/'apps/ios/Sources/MessageFilterCore').glob('*.swift'))
    deps += [ROOT/'apps/ios/Tools/MessageFilterPredictionAudit/main.swift',ROOT/'apps/ios/Tests/MessageFilterCoreTests/TransformerExpertRoutingTests.swift',
        Path(__file__),Path(__file__).with_name('expert_routing_v71.py'),Path(__file__).with_name('prepare_routing_v71.py'),
        Path(__file__).with_name('author_routing_v71.py'),Path(__file__).with_name('tests')/'test_expert_routing_v71.py',
        Path(__file__).with_name('fusion_v68.py'),Path(__file__).with_name('study_action_head_v67.py')]
    write(PROTOCOL,dict(name='signal-expert-routing-v71',createdUTC=datetime.now(timezone.utc).isoformat(),
        training=str(TRAINING.relative_to(ROOT)),calibration=str(CALIBRATION.relative_to(ROOT)),reservedValidation=old['reservedValidation'],
        fullHeadEpochs=full_epochs,fullHeads=full_heads,classWeights=old['classWeights'],cohorts=cohorts,seeds=list(SEEDS),methods=list(METHODS),
        runtime=str(runtime.relative_to(ROOT)),
        crossfit='Three folds of four complete trilingual families,48held rows each; every fold head fits old3457+other96=3553 rows for18epochs504updates with v69 loss/optimizer. OOF outputs use the same pre-fixed12/5 epochs as full heads. Retained SAM is frozen; only144 newly authored training rows are gate targets. No claim that original3457 fine predictions are out of fold.',
        gate='19parameter logistic selector on18 probability/margin/entropy/action features. Risk costs: correct0,normal filtering5,harmful miss5,other action error1. Target cheaper expert;ties favor fine with weight.1. AdamW lr.02,warmup16/cosine.002,decay0,explicit.01L2weights,clip1,8batches per epoch,18epochs144updates. Init weights0,bias-log9. In-sample versus OOF head predictions are the only gate-training difference.',
        routing='Preference>=.5 selects head; else original fine leaf. Agreed actions retain original fine decision. Head business>=.60 or other action>=.5 required; uncertain head returns fine. Business action confidence is separate from original fine confidence, preserving subfolder/mapping guards. v70 rules fixed.',
        selection='Freshcal72,epoch0plus18gateepochs. No example-level lost harmful or new normal junk/promotion; no per-language commercial/harmful recall decline; zero normal filtering,action/harmful>=90%,action nondecrease and strict gain. Rank harmful,action,earlier epoch. Only crossfit may qualify; in-sample and head-only are diagnostics. Both seeds required; no alternative adoption after veto.',
        acceptance='Fix diagnostics before history. Five old cohorts<=2normal junk and no new junk/promotion or lost harmful;action drop<=.5pp. Spentv68/v69cal require action>=90%,normal junk<=2,promotion nonincrease. Per-language commercial/harmful nondecrease. Only if primary passes all, score reservedv68validation72 once under fresh gates. No historical epoch reselect.',
        sourceIndependentFinal=False,releaseEligible=False,filesSHA256={str(f.relative_to(ROOT)):sha(f) for f in sorted(set(deps))}))
    print('Sealed family-crossfit gate protocol before OOF fitting or calibration inference.',flush=True)


def replay(rows,full,name,p,heads=None,preferences=None,mode='routing',base=None):
    if heads is None:inputs=[{k:v for k,v in r.items() if k!='probabilities'} for r in full]
    else:
        inputs=[{**r,'actionProbabilities':h} for r,h in zip(full,heads,strict=True)]
        if mode=='routing':
            assert preferences is not None
            for x,v in zip(inputs,preferences,strict=True):x['headPreference']=float(v)
    source=OUT/f'{name}-predictions.ndjson';output=OUT/f'{name}-swift.ndjson'
    with source.open('x') as f:
        for r in inputs:f.write(json.dumps(r,ensure_ascii=False)+'\n')
    cmd=[str(ROOT/p['runtime']),str(source),str(output)]
    if heads is not None:cmd+=['--expert-routing' if mode=='routing' else '--action-fusion']
    run=subprocess.run(cmd,capture_output=True,text=True)
    if run.returncode:raise RuntimeError(run.stderr[-4000:])
    decisions=read(output);a=actions()
    for i,(r,x,d) in enumerate(zip(rows,full,decisions,strict=True)):
        assert r['text']==x['text'] and r['label']==x['label']==d['label']
        assert d['index']==i and d['rawPrediction']==x['prediction'] and d['confidence']==x['confidence'] and d['fallbackReason']=='none'
    m=policy_metrics(rows,[{**x,**d} for x,d in zip(full,decisions,strict=True)],a)
    m.update(inputSHA256=sha(source),outputSHA256=sha(output),harmfulLost=0,normalNewJunk=0,normalNewPromotion=0,normalJunkCorrected=0,normalCorrectActionsLost=0)
    if base is not None:
        for r,b,d in zip(rows,base,decisions,strict=True):
            if r['filterReview']['inputForm']=='scenario-description':continue
            kind=r['filterReview']['kind'];before=b['engineAction'];after=d['engineAction']
            m['harmfulLost']+=kind=='harmful' and before=='junk' and after!='junk'
            m['normalNewJunk']+=kind=='normal' and before!='junk' and after=='junk'
            m['normalNewPromotion']+=kind=='normal' and before!='promotion' and after=='promotion'
            m['normalJunkCorrected']+=kind=='normal' and before=='junk' and after not in ('junk','promotion')
            m['normalCorrectActionsLost']+=kind=='normal' and before==a[r['label']] and after!=a[r['label']]
    return decisions,m


def combined(seed):
    import torch
    old=torch.load(V67/f'{seed}-training-features.pt',weights_only=True)
    new=torch.load(V69/f'{seed}-new-training-features.pt',weights_only=True)
    return dict(features=torch.cat([old['features'],new['features']]),logits=torch.cat([old['logits'],new['logits']]),
                textSHA256=old['textSHA256']+new['textSHA256'])


def crossfit():
    import torch
    torch.set_num_threads(2);p=check();rows=read(TRAINING);meta=rows[3457:];a=actions();split=folds(meta)
    y=torch.tensor([target(r['label'],a) for r in rows])
    spec=json.loads((EXP/'signal-language-control-v52-weights.json').read_text())['entries']
    w=torch.tensor([spec[identity(r['text'])]['weight'] if i<3457 else 1. for i,r in enumerate(rows)])*torch.tensor(p['classWeights'])[y]
    stats={}
    for seed in SEEDS:
        cache=combined(seed);assert cache['textSHA256']==[identity(r['text']) for r in rows]
        full=raw_predictions(cache,rows,seed)[3457:];x=cache['features'];oof=[None]*144;fold_stats=[]
        for fold in range(3):
            held=[i for i,f in enumerate(split) if f==fold]
            train=list(range(3457))+[3457+i for i,f in enumerate(split) if f!=fold]
            assert not set(train)&{3457+i for i in held} and len(train)==3553
            tx=x[train];ty=y[train];tw=w[train];head=torch.nn.Linear(384,4)
            torch.nn.init.zeros_(head.weight);torch.nn.init.zeros_(head.bias)
            optimizer=torch.optim.AdamW(head.parameters(),lr=.001,weight_decay=.01,eps=1e-8)
            folder=OUT/f'fold-{seed}-{fold}';folder.mkdir();history=[];step=0
            for epoch in range(1,19):
                order=torch.randperm(len(train),generator=torch.Generator().manual_seed(seed*100+epoch))
                for batch in torch.tensor_split(order,28):
                    step+=1;lr=.001*step/50 if step<=50 else .0001+.0009*.5*(1+math.cos(math.pi*(step-50)/454))
                    optimizer.param_groups[0]['lr']=lr;optimizer.zero_grad(set_to_none=True)
                    objective=(loss(head(tx[batch]),ty[batch])*tw[batch]).sum()/tw[batch].sum()
                    objective.backward();torch.nn.utils.clip_grad_norm_(head.parameters(),1.);optimizer.step()
                optimizer.zero_grad(set_to_none=True);objective=(loss(head(tx),ty)*tw).sum()/tw.sum();objective.backward()
                rms=float(torch.cat([v.grad.flatten() for v in head.parameters()]).square().mean().sqrt())
                history.append(dict(epoch=epoch,trainingLoss=float(objective.detach()),gradientRMS=rms,updates=step,learningRate=lr))
                torch.save(head.state_dict(),folder/f'epoch-{epoch:03d}.pt')
                if epoch==p['fullHeadEpochs'][str(seed)]:
                    values=head_values(head,x[[3457+i for i in held]])
                    for i,v in zip(held,values,strict=True):assert oof[i] is None;oof[i]=v
            info=dict(fold=fold,heldMetaIndices=held,trainIndices=train,heldFamilies=sorted({meta[i]['familyId'] for i in held}),history=history,selectedEpoch=p['fullHeadEpochs'][str(seed)])
            write(folder/'training.json',info);fold_stats.append(info)
            print('OOF head completed',seed,fold,'18epochs504updates',flush=True)
        assert all(v is not None for v in oof)
        insample=head_values(full_head(seed,p),x[3457:])
        base,bm=replay(meta,full,f'meta-{seed}-leaf',p)
        payload=dict(textSHA256=[identity(r['text']) for r in meta],methods={});meta_stats={}
        for method,heads in [('crossfit',oof),('insample',insample)]:
            ds,m=replay(meta,full,f'meta-{seed}-{method}-head',p,heads,[1.]*len(meta),base=base)
            yy,ww=targets(meta,base,ds,a);xx=features(full,heads,a)
            payload['methods'][method]=dict(features=xx,target=yy,weight=ww)
            meta_stats[method]=dict(preferHead=int(yy.sum()),preferFine=len(yy)-int(yy.sum()),riskWeightSum=float(ww.sum()),policy=m)
        torch.save(payload,OUT/f'meta-{seed}.pt');stats[str(seed)]=dict(methods=meta_stats,baseline=bm,folds=[{k:v for k,v in f.items() if k!='history'} for f in fold_stats])
    write(OUT/'crossfit.json',dict(results=stats,protocolSHA256=sha(PROTOCOL),
        filesSHA256={str(f.relative_to(ROOT)):sha(f) for f in [*OUT.glob('fold-*/*'),*OUT.glob('meta-*.pt')]}))


def gate_fit():
    import torch
    torch.set_num_threads(2);p=check();receipt=json.loads((OUT/'crossfit.json').read_text())
    for n,h in receipt['filesSHA256'].items():assert sha(ROOT/n)==h
    for seed in SEEDS:
        data=torch.load(OUT/f'meta-{seed}.pt',weights_only=True)
        for method in METHODS:
            d=data['methods'][method];x,y,w=d['features'],d['target'],d['weight']
            gate=torch.nn.Linear(18,1);torch.nn.init.zeros_(gate.weight);torch.nn.init.constant_(gate.bias,-math.log(9))
            optimizer=torch.optim.AdamW(gate.parameters(),lr=.02,weight_decay=0,eps=1e-8)
            folder=OUT/f'gate-{method}-{seed}';folder.mkdir();history=[];step=0
            def objective(ix):return (torch.nn.functional.binary_cross_entropy_with_logits(gate(x[ix]).squeeze(-1),y[ix],reduction='none')*w[ix]).sum()/w[ix].sum()+.01*gate.weight.square().sum()
            initial=float(objective(torch.arange(144)).detach())
            for epoch in range(1,19):
                order=torch.randperm(144,generator=torch.Generator().manual_seed(seed*100+epoch))
                for batch in torch.tensor_split(order,8):
                    step+=1;lr=.02*step/16 if step<=16 else .002+.018*.5*(1+math.cos(math.pi*(step-16)/128))
                    optimizer.param_groups[0]['lr']=lr;optimizer.zero_grad(set_to_none=True)
                    value=objective(batch);value.backward();torch.nn.utils.clip_grad_norm_(gate.parameters(),1.);optimizer.step()
                optimizer.zero_grad(set_to_none=True);value=objective(torch.arange(144));value.backward()
                rms=float(torch.cat([v.grad.flatten() for v in gate.parameters()]).square().mean().sqrt())
                history.append(dict(epoch=epoch,trainingLoss=float(value.detach()),gradientRMS=rms,updates=step,learningRate=lr))
                torch.save(gate.state_dict(),folder/f'epoch-{epoch:03d}.pt')
            write(folder/'training.json',dict(initialLoss=initial,history=history,stationarityProven=False))
            print('Gate completed',method,seed,history[-1],flush=True)
    write(OUT/'gate-fit.json',dict(protocolSHA256=sha(PROTOCOL),crossfitSHA256=sha(OUT/'crossfit.json'),
        filesSHA256={str(f.relative_to(ROOT)):sha(f) for f in OUT.glob('gate-*/*')}))


def gate_values(method,seed,epoch,x):
    import torch
    gate=torch.nn.Linear(18,1);gate.load_state_dict(torch.load(OUT/f'gate-{method}-{seed}'/f'epoch-{epoch:03d}.pt',weights_only=True))
    with torch.no_grad():return gate(x).squeeze(-1).double().sigmoid().tolist()


def extract(seed,rows,name):
    from transformers import AutoModelForSequenceClassification,AutoTokenizer
    path=ROOT/verify_checkpoint(model_manifest(seed))['checkpoint']
    model=AutoModelForSequenceClassification.from_pretrained(path,local_files_only=True,attn_implementation='eager').eval();model.requires_grad_(False)
    return extract_for_model(model,AutoTokenizer.from_pretrained(path,local_files_only=True),rows,OUT/f'{seed}-{name}-features.pt')


def calibrate():
    import torch
    torch.set_num_threads(2);p=check();receipt=json.loads((OUT/'gate-fit.json').read_text())
    for n,h in receipt['filesSHA256'].items():assert sha(ROOT/n)==h
    rows=read(CALIBRATION);results={};controls={}
    for seed in SEEDS:
        cache=extract(seed,rows,'calibration');full=raw_predictions(cache,rows,seed);heads=head_values(full_head(seed,p),cache['features'])
        x=features(full,heads,actions());base,bm=replay(rows,full,f'calibration-{seed}-leaf',p)
        controls[str(seed)]={}
        for mode in ('head','locked'):
            _,m=replay(rows,full,f'calibration-{seed}-{mode}',p,heads,[1.]*len(rows),mode='routing' if mode=='head' else 'locked',base=base)
            controls[str(seed)][mode]=m
        for method in METHODS:
            records=[{**bm,'epoch':0}]
            for epoch in range(1,19):
                _,m=replay(rows,full,f'calibration-{method}-{seed}-{epoch:03d}',p,heads,gate_values(method,seed,epoch,x),base=base)
                records.append({**m,'epoch':epoch})
                print('calibration',method,seed,epoch,m['policy']['actionCorrect'],m['policy']['normalToJunk'],m['harmfulLost'],safety(m,bm),flush=True)
            diagnostic=max(records[1:],key=lambda r:(r['policy']['actionCorrect'],-r['policy']['normalToJunk'],r['policy']['harmfulCaught'],-r['epoch']))
            results[f'{method}-{seed}']=dict(records=records,selected=select(records),diagnosticEpoch=diagnostic['epoch'])
    qualified=all(results[f'crossfit-{seed}']['selected']['epoch']>0 for seed in SEEDS)
    fixed={k:r['selected']['epoch'] or r['diagnosticEpoch'] for k,r in results.items()}
    write(OUT/'selection.json',dict(results=results,controls=controls,primaryQualified=qualified,historicalEpochs=fixed,
        selectedUTC=datetime.now(timezone.utc).isoformat(),protocolSHA256=sha(PROTOCOL),reservedValidationScored=False,
        gateSHA256={k:sha(OUT/f'gate-{k}'/f'epoch-{e:03d}.pt') for k,e in fixed.items()}))


def historical(seed,name,spec):
    import torch
    rows=read(ROOT/spec['gold'])
    if name in ('old72','v68-calibration72','v69-calibration72'):
        path=V67/f'{seed}-development-features.pt' if name=='old72' else (V68 if name=='v68-calibration72' else V69)/f'{seed}-calibration-features.pt'
        cache=torch.load(path,weights_only=True);full=raw_predictions(cache,rows,seed)
    else:
        cache=torch.load(V67/f'diagnostic-{seed}-{name}-features.pt',weights_only=True)
        full=read(V65/f'retained-{seed}-{name}-transactionSum-predictions.ndjson')
    assert cache['textSHA256']==[identity(r['text']) for r in rows]
    previous=V70/(f'calibration-{seed}-leaf-swift.ndjson' if name=='v69-calibration72' else f'history-{seed}-{name}-leaf-swift.ndjson')
    return rows,cache,full,read(previous)


def review():
    import torch
    torch.set_num_threads(2);p=check();s=json.loads((OUT/'selection.json').read_text())
    for k,e in s['historicalEpochs'].items():assert sha(OUT/f'gate-{k}'/f'epoch-{e:03d}.pt')==s['gateSHA256'][k]
    write(OUT/'review-start.json',dict(selectionSHA256=sha(OUT/'selection.json'),primaryQualified=s['primaryQualified']))
    results={};gates={f'{method}-{seed}':True for method in METHODS for seed in SEEDS}
    for seed in SEEDS:
        h=full_head(seed,p)
        for name,spec in p['cohorts'].items():
            rows,cache,full,previous=historical(seed,name,spec);heads=head_values(h,cache['features']);x=features(full,heads,actions())
            base,bm=replay(rows,full,f'history-{seed}-{name}-leaf',p);assert base==previous,'default runtime drift'
            for method in ('head','locked',*METHODS):
                preferences=[1.]*len(rows) if method in ('head','locked') else gate_values(method,seed,s['historicalEpochs'][f'{method}-{seed}'],x)
                ds,m=replay(rows,full,f'history-{method}-{seed}-{name}',p,heads,preferences,mode='locked' if method=='locked' else 'routing',base=base)
                passed=safety(m,bm,'boundary' if name.startswith(('v68','v69')) else 'historical')
                if method in METHODS:gates[f'{method}-{seed}']&=passed
                changes=[dict(index=i,text=r['text'],label=r['label'],language=r['language'],kind=r['filterReview']['kind'],before=b,after=d)
                    for i,(r,b,d) in enumerate(zip(rows,base,ds,strict=True)) if any(b[k]!=d[k] for k in ('engineAction','engineLabel','engineSubAction'))]
                results.setdefault(f'{method}-{seed}',{})[name]=dict(baseline=bm,candidate=m,passed=passed,changes=changes)
                print('history',method,seed,name,m['policy']['actionCorrect'],m['policy']['normalToJunk'],m['harmfulLost'],passed,flush=True)
    qualified=s['primaryQualified'] and all(gates[f'crossfit-{seed}'] for seed in SEEDS)
    write(OUT/'historical.json',dict(results=results,gates=gates,validationAuthorized=qualified,selectionSHA256=sha(OUT/'selection.json'),adopted=False,releaseEligible=False))


def validate():
    import torch
    torch.set_num_threads(2);p=check();s=json.loads((OUT/'selection.json').read_text());h=json.loads((OUT/'historical.json').read_text())
    assert h['selectionSHA256']==sha(OUT/'selection.json')
    if not h['validationAuthorized']:
        write(OUT/'verdict.json',dict(accepted=False,reservedValidationScored=False,reason='Primary crossfit pair did not pass fixed calibration and historical gates; no alternative selected.',adopted=False,releaseEligible=False));return
    write(OUT/'validation-start.json',dict(selectionSHA256=sha(OUT/'selection.json'),historicalSHA256=sha(OUT/'historical.json')))
    rows=read(ROOT/p['reservedValidation']);results={}
    for seed in SEEDS:
        cache=extract(seed,rows,'reserved-validation');full=raw_predictions(cache,rows,seed);heads=head_values(full_head(seed,p),cache['features'])
        x=features(full,heads,actions());base,bm=replay(rows,full,f'validation-{seed}-leaf',p)
        _,m=replay(rows,full,f'validation-crossfit-{seed}',p,heads,gate_values('crossfit',seed,s['historicalEpochs'][f'crossfit-{seed}'],x),base=base)
        results[str(seed)]=dict(baseline=bm,candidate=m,passed=safety(m,bm))
    write(OUT/'verdict.json',dict(results=results,localQualificationPassed=all(r['passed'] for r in results.values()),reservedValidationScored=True,adopted=False,releaseEligible=False,sourceIndependentFinal=False))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase',choices=('seal','crossfit','gate_fit','calibrate','review','validate'))
    globals()[parser.parse_args().phase]()
