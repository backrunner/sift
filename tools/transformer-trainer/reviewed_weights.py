"""Fixed bounded training-only weights, with no model-error or evaluation feedback."""
from collections import Counter
import hashlib
import json
import math


def identity(text):return hashlib.sha256(text.encode()).hexdigest()


def row_weight(row):
    if row['label']=='spam':return {'zh':2.,'ja':2.,'en':1.4,'vi':1.}[row['language']]
    if row['label'] in ('promotion','carrier.promotion'):return 1.2
    if row['label']=='__sift_abstain__':return {'en':.65,'zh':.85}.get(row['language'],1.)
    return 1.


def build_spec(rows,training_sha):
    entries={identity(r['text']):{'label':r['label'],'language':r['language'],'weight':row_weight(r)} for r in rows}
    if len(entries)!=len(rows):raise ValueError('duplicate weight identities')
    mass=Counter();counts=Counter()
    for r in rows:
        action='junk' if r['label']=='spam' else 'promotion' if r['label'] in ('promotion','carrier.promotion') else 'none' if r['label']=='__sift_abstain__' else 'transaction'
        mass[action]+=row_weight(r);counts[action]+=1
    total=sum(mass.values());sum_sq=sum(e['weight']**2 for e in entries.values())
    return {'kind':'reviewed-training-row-weights','trainingSHA256':training_sha,'entries':entries,
        'range':[min(e['weight'] for e in entries.values()),max(e['weight'] for e in entries.values())],
        'rawActionCounts':dict(counts),'weightedActionFractions':{a:n/total for a,n in mass.items()},
        'effectiveSampleSize':total*total/sum_sq,'newIndependentRows':0,
        'rule':'Junk zh/ja2,en1.4,vi1; legitimate promotion1.2; chat en0.65,zh0.85; all other rows1. All roots once each epoch.',
        'meaning':'Training objective weights, not an estimate of deployment prevalence; translations remain correlated.'}


def validate(rows,spec):
    if spec.get('kind')!='reviewed-training-row-weights':raise ValueError('invalid weighting contract')
    entries=spec['entries']
    if set(entries)!={identity(r['text']) for r in rows}:raise ValueError('weight membership mismatch')
    for r in rows:
        e=entries[identity(r['text'])]
        if e['label']!=r['label'] or e['language']!=r['language']:raise ValueError('weight label/language drift')
        if not math.isfinite(e['weight']) or not .5<=e['weight']<=2.:raise ValueError('unsafe/unbounded weight')


def install(path,enabled):
    import train_mmbert as train
    spec=json.loads(path.read_text());original=train.make_collate
    def make_collate(*args,**kwargs):
        base=original(*args,**kwargs)
        def collate(items):
            import torch
            encoded=base(items)
            weights=[spec['entries'][identity(r['text'])]['weight'] if enabled else 1. for r in items]
            encoded['loss_weights']*=torch.tensor(weights,dtype=encoded['loss_weights'].dtype)
            return encoded
        return collate
    train.make_collate=make_collate
    return original
