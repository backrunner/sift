"""Group unseen reviewed public messages before bounded recall experiments."""
from collections import Counter,defaultdict
import hashlib
import json
from pathlib import Path

from import_reviewed_public import keys
from recall_public import ascii_family,digest


def root_domain(host):
    labels=host.split('.')
    return '.'.join(labels[-3:] if '.'.join(labels[-2:]) in {'com.vn','com.au','co.uk','co.jp'} else labels[-2:])


def split_pool(rows):
    parent=list(range(len(rows)))
    def find(x):
        while parent[x]!=x:parent[x]=parent[parent[x]];x=parent[x]
        return x
    seen={}
    for i,row in enumerate(rows):
        features=['family:'+ascii_family(row['text'])]
        # Treat distinct messages from the same attack-host campaign as one
        # group. Shared official benign portals do not establish a campaign.
        if row['label']=='spam':features+=['attack-host:'+root_domain(h) for h in row['hosts']]
        for key in features:
            if key in seen:parent[find(i)]=find(seen[key])
            else:seen[key]=i
    groups=defaultdict(list)
    for i,row in enumerate(rows):groups[find(i)].append(row)
    assignments=[]
    for group in groups.values():
        identity=digest('|'.join(sorted(r['originalSHA256'] for r in group)))
        side='development' if int(digest('recall-v9-source-split:'+identity)[:8],16)%3==0 else 'train'
        assignments.extend((r,side,identity) for r in group)
    return assignments


def main():
    root=Path('build/signal-recall-v9-20261028')
    pool=json.loads((root/'reviewed-pool.json').read_text());assignments=split_pool(pool)
    train=[json.loads(l) for l in Path('tools/apple-trainer/Training/signal-approved-v8.ndjson').read_text().splitlines()]
    development=[json.loads(l) for l in Path('tools/transformer-trainer/Evaluation/signal-development-v8.ndjson').read_text().splitlines()]
    metadata=[];extra_train=[];extra_dev=[]
    for row,side,group in assignments:
        public={k:row[k] for k in ('text','label','language','source')}
        (extra_train if side=='train' else extra_dev).append(public)
        metadata.append({'textSHA256':digest(row['text']),'originalSHA256':row['originalSHA256'],
            'groupSHA256':group,'split':side,'label':row['label'],'source':row['source']})
    if sum(r['label']=='spam' for r in extra_dev)<12:raise ValueError('insufficient independent positive development support')
    train+=extra_train;development+=extra_dev
    train_keys={digest(k) for r in train for k in keys(r['text'],family=True)}
    dev_keys={digest(k) for r in development for k in keys(r['text'],family=True)}
    if train_keys&dev_keys:raise ValueError('new train/development family overlap')
    paths=[Path('tools/apple-trainer/Training/signal-recall-v9.ndjson'),
           Path('tools/transformer-trainer/Evaluation/signal-recall-development-v9.ndjson')]
    for p,rows in zip(paths,(train,development)):p.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows))
    (root/'new-development.ndjson').write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in extra_dev))
    old=json.loads(Path('tools/apple-trainer/Training/signal-approved-v8.json').read_text())
    protected=set(old['protectedSignatureSHA256'])|dev_keys
    m={**old,'dataRevision':1,'training':str(paths[0]),'development':str(paths[1]),
        'trainingCount':len(train),'developmentCount':len(development),
        'sourceCounts':Counter(r['source'].split(':')[0] for r in train),
        'protectedSignatureSHA256':sorted(protected),'reviewScope':'V8r2 foundation plus new individually content-reviewed public examples. Group split also isolates malicious root-domain campaigns. No old failed examples are paraphrased or relabelled.',
        'newReviewedTrainCount':len(extra_train),'newReviewedDevelopmentCount':len(extra_dev),
        'newDevelopmentSpamCount':sum(r['label']=='spam' for r in extra_dev),
        'qualityReport':'docs/engineering/signal-recall-v9-corpus.json'}
    dependencies=[*paths,Path('packages/taxonomy/taxonomy.json'),
        Path('tools/apple-trainer/Training/retired-signal-samples-v8.json'),
        Path('tools/apple-trainer/Training/public-sms-recall-reviews-v9.json')]
    m['filesSHA256']={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in dependencies}
    Path('tools/apple-trainer/Training/signal-recall-v9.json').write_text(json.dumps(m,ensure_ascii=False,indent=2)+'\n')
    report={'trainingCount':len(train),'developmentCount':len(development),
        'newTrainingLabels':Counter(r['label'] for r in extra_train),'newDevelopmentLabels':Counter(r['label'] for r in extra_dev),
        'assignments':metadata,'newSourceBodiesReviewed':247,'newSourceBodiesApproved':108,
        'newSourceUsage':'Vietnamese official train only; no upstream test record is trained.',
        'reviewMethod':'AI-assisted content review, not independent human/native-speaker adjudication.',
        'rawSourceSHA256':{'vietnamese-train.csv':hashlib.sha256((root/'sources/vietnamese-train.csv').read_bytes()).hexdigest(),
            'imc25.csv':hashlib.sha256(Path('build/public-source-audit-20261027/imc25.csv').read_bytes()).hexdigest()},
        'old215DevelopmentIsReused':True,'newDevelopmentIsForSelectionNotAFinalTest':True,
        'finalHoldoutUsed':False,'releaseEligible':False}
    Path(m['qualityReport']).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ('assignments','rawSourceSHA256')},ensure_ascii=False,indent=2))


if __name__=='__main__':main()
