"""Reserve new public evaluation groups before annotation or inference.

Only accepted anonymous bodies are materialized. Candidate/rejection manifests
retain source hashes, group hashes and decisions, never rejected bodies.
"""
import argparse
from collections import Counter,defaultdict
import csv
import hashlib
import html
import io
import json
from pathlib import Path
import re
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET
import zipfile

from approved_signal import ROOT,verify
from curate_dataset import normalize
from import_reviewed_public import keys
from recall_public import ascii_family,digest
from prepare_recall_signal import root_domain
from retired_samples import RetiredSamples
from sms_signatures import BARE_URL_PATTERN

OUT=ROOT/'build/signal-generalization-v15-20261028'
MANIFEST=OUT/'public-candidates.json'
REVIEWS=ROOT/'tools/apple-trainer/Evaluation/public-generalization-v15-review.json'
BUSINESS=re.compile(r'通知|您的|您有|订单|培训|会议|缴费|账单|验证码|快递|物流|申请|预约|入职|项目|截止|\b(?:account|invoice|meeting|scheduled|appointment|approved|application|deadline|training|project|bank|delivery|order|courier|verification|attendance|roster)\b',re.I)
HOST=re.compile(r'https?://[^\s<>。！？，；]+',re.I)


def valid_contributor(value):
    # NUS uses both numeric IDs and opaque anonymized hashes. Neither is a
    # phone/user identity to be exported; grouping retains only a digest.
    return bool(re.fullmatch(r'[A-Za-z0-9_-]{1,128}',value or '')) and value.casefold() not in {
        'unknown','none','null','0','na','unspecified'}


def public_hosts(text):
    result=set()
    for pattern in (HOST,BARE_URL_PATTERN):
        for match in pattern.finditer(html.unescape(text)):
            value=match.group().rstrip('.,;!?)')
            try:host=urlsplit(value if '://' in value else 'https://'+value).hostname
            except ValueError:continue
            if host:result.add(host.lower())
    return result


def write(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')


def render(text):
    """Keep public hosts; strip paths, never reconstruct missing fraud evidence."""
    text=html.unescape(text).replace('\\n',' ').replace('\\r',' ')
    hosts=[]
    def url(m):
        value=m.group().rstrip('.,;!?)')
        host=urlsplit(value if '://' in value else 'https://'+value).hostname
        if not host or not re.fullmatch(r'(?:[a-z0-9-]+\.)+[a-z]{2,}',host,re.I):
            raise ValueError('malformed-public-host')
        if re.search(r'\d{7,}|[a-z0-9]{25}',host,re.I):raise ValueError('host-identifier')
        hosts.append(host.lower())
        return 'SIFTPUBLICURLSLOT'+chr(65+len(hosts)-1)+'END'
    text=HOST.sub(url,text)
    text=BARE_URL_PATTERN.sub(url,text)
    missing='<URL>' in text
    text=text.replace('<URL>','')
    if re.search(r'<[A-Z_#]+>|\[(?!TB\]|QC\])[A-Z_]+\]',text):raise ValueError('unrecoverable-anonymizer')
    if re.search(r'\b\d{7,}\b|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}',text):raise ValueError('unreviewed-identifier')
    for index,host in enumerate(hosts):
        text=text.replace('SIFTPUBLICURLSLOT'+chr(65+index)+'END','https://'+host+'/review')
    text=normalize(text)
    if not 12<=len(text)<=600:raise ValueError('incomplete-or-long')
    return text,sorted(set(hosts)),missing


def source_records():
    prior=json.loads((ROOT/'tools/apple-trainer/Training/public-sms-reviews-v1.json').read_text())
    sources={r['id']:r for r in prior['sources'] if r['id'] in ('nus-en','nus-zh','mendeley-2022','imc25')}
    cache=ROOT/'build/public-source-audit-20261027'
    result=[]
    for name,spec in sources.items():
        file=cache/spec['file']
        if hashlib.sha256(file.read_bytes()).hexdigest()!=spec['sha256']:raise ValueError('raw source drift: '+name)
        if name.startswith('nus-'):
            with zipfile.ZipFile(file) as archive:top=ET.fromstring(archive.read(spec['member']))
            for message in top.findall('message'):
                text=normalize(message.findtext('text',''))
                result.append({'source':name,'originalSHA256':digest(text),'raw':text,
                    'language':name[-2:],'contributor':message.findtext('source/userProfile/userID',''),
                    'sourceLabel':'unlabelled','translation':''})
        else:
            if spec['format']=='zip-csv':
                with zipfile.ZipFile(file) as archive:data=archive.read(spec['member']).decode('utf-8-sig')
            else:data=file.read_text(encoding='utf-8-sig')
            for row in csv.DictReader(io.StringIO(data)):
                text=normalize(row.get(spec.get('textField','text'),''))
                language=spec.get('language') or {'English':'en','Chinese':'zh','Japanese':'ja'}.get(row.get('language'))
                if language not in ('en','zh','ja'):continue
                result.append({'source':name,'originalSHA256':digest(text),'raw':text,'language':language,
                    'contributor':None,'sourceLabel':row.get(spec.get('labelField','label'),'reported'),
                    'translation':row.get('translation','')})
    return sources,result


def previous_reviews():
    known=defaultdict(set)
    for p in (ROOT/'tools/apple-trainer/Training').glob('public-sms-*.json'):
        for r in json.loads(p.read_text()).get('reviews',[]):
            if key:=r.get('key',r.get('originalSHA256')):known[r['source']].add(key)
    return known


def prepare_pool():
    sources,records=source_records();known=previous_reviews();used_users=set();used_hosts=set()
    contract=verify(ROOT/'tools/apple-trainer/Training/signal-reviewed-v13.json')
    protected=set(contract['protectedSignatureSHA256']);ascii_protected=set()
    for file in [ROOT/contract['training'],ROOT/'build/signal-corpus-review-20261027/all-eval-reviewed.ndjson',
                 ROOT/'tools/transformer-trainer/Evaluation/signal-development-v8.ndjson',
                 ROOT/'tools/transformer-trainer/Evaluation/signal-development-v11.ndjson']:
        for line in file.read_text().splitlines():
            row=json.loads(line);protected.update(digest(k) for k in keys(row['text'],family=True));ascii_protected.add(ascii_family(row['text']))
            used_hosts.update(root_domain(h) for h in public_hosts(row['text']))
    for row in records:
        if row['originalSHA256'] not in known[row['source']]:continue
        if row['contributor']:used_users.add(row['contributor'])
        used_hosts.update(root_domain(h) for h in public_hosts(row['raw']))
    retirement=RetiredSamples();buckets=defaultdict(list);exclusions=Counter()
    for row in records:
        if row['originalSHA256'] in known[row['source']]:exclusions['previous-reviewed-key']+=1;continue
        if row['source'].startswith('nus-') and (not valid_contributor(row['contributor']) or row['contributor'] in used_users):
            exclusions['previous-or-missing-contributor']+=1;continue
        try:text,hosts,missing=render(row['raw'])
        except ValueError as e:exclusions[str(e)]+=1;continue
        signatures={digest(k) for k in keys(text,family=True)}
        if row['translation']:
            translation=normalize(html.unescape(row['translation']).replace('<URL>',''))
            signatures.update(digest(k) for k in keys(translation,family=True))
        if signatures&protected or ascii_family(text) in ascii_protected:exclusions['protected-family']+=1;continue
        if any(root_domain(h) in used_hosts for h in hosts):exclusions['previous-exposed-host']+=1;continue
        if retirement.reason({'text':text,'label':'__sift_abstain__','source':'public-review-candidate-v15'}):
            exclusions['retired-content']+=1;continue
        if row['source'].startswith('nus-'):
            bucket=row['source']+(':business' if BUSINESS.search(text) else ':conversation')
            group=digest('nus-contributor:'+row['contributor'])
        elif row['source']=='mendeley-2022':
            bucket=row['source']+(':ham' if row['sourceLabel'].lower()=='ham' else ':reported-risk')
            group=digest('host:'+root_domain(hosts[0])) if hosts else ascii_family(text)
        else:
            bucket='imc25:'+row['language']+(':host' if hosts else ':no-host')
            group=digest('host:'+root_domain(hosts[0])) if hosts else ascii_family(text)
        buckets[bucket].append({**row,'text':text,'hosts':hosts,'missingURL':missing,
            'groupSHA256':group,'signatures':signatures,'bucket':bucket})
    caps={'nus-en:business':30,'nus-zh:business':50,'nus-en:conversation':15,'nus-zh:conversation':15,
        'mendeley-2022:reported-risk':90,'mendeley-2022:ham':16,
        'imc25:en:host':35,'imc25:en:no-host':20,'imc25:ja:host':10,'imc25:ja:no-host':20,
        'imc25:zh:host':10,'imc25:zh:no-host':10}
    selected=[];seen=set();groups=set();selected_hosts=set()
    # Business notices take precedence over casual chat within a contributor.
    for bucket in caps:
        count=0
        for row in sorted(buckets[bucket],key=lambda r:digest('v15-candidate:'+r['originalSHA256'])):
            roots={root_domain(h) for h in row['hosts']}
            if row['groupSHA256'] in groups or row['signatures']&seen or roots&selected_hosts:continue
            selected.append(row);seen.update(row['signatures']);groups.add(row['groupSHA256']);selected_hosts.update(roots);count+=1
            if count>=caps[bucket]:break
    # Whole groups are split in fixed hash order within source strata, before
    # body review or any inference. No split seed is searched.
    strata=defaultdict(list)
    for row in selected:strata[row['bucket']].append(row)
    for rows in strata.values():
        for i,row in enumerate(sorted(rows,key=lambda r:digest('v15-split:'+r['groupSHA256']))):
            row['split']='development' if i%3==0 else 'final'
    selected.sort(key=lambda r:(r['source'],r['language'],r['originalSHA256']))
    return sources,selected,exclusions,protected


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('stage',choices=['discover','view','materialize'])
    p.add_argument('--start',type=int,default=0);p.add_argument('--end',type=int,default=60)
    args=p.parse_args()
    if args.stage=='discover':
        if MANIFEST.exists():raise ValueError('candidate split already frozen')
        sources,rows,excluded,protected=prepare_pool()
        candidates=[{'id':i,**{k:r[k] for k in ['source','originalSHA256','language','sourceLabel','groupSHA256','bucket','split']},
            'renderedSHA256':digest(r['text'])} for i,r in enumerate(rows)]
        write(MANIFEST,{'schemaVersion':1,'kind':'public-evaluation-candidate-groups','sources':sources,
            'preparationSourceSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'protocolSHA256':hashlib.sha256((ROOT/'tools/transformer-trainer/experiments/signal-generalization-v15-protocol.json').read_bytes()).hexdigest(),
            'candidates':candidates,'exclusions':dict(excluded),'protectedSignatureSHA256':sorted(protected),
            'scope':'Source binary reports are not gold; body review without model predictions is required. No model trained or scored.'})
        print(json.dumps({'candidates':len(candidates),'buckets':Counter(r['bucket'] for r in rows),
            'splits':Counter(r['split'] for r in rows),'exclusions':excluded},indent=2));return
    manifest=json.loads(MANIFEST.read_text());_,raw=source_records();lookup={(r['source'],r['originalSHA256']):r for r in raw}
    if args.stage=='view':
        for row in manifest['candidates'][args.start:args.end]:
            text,hosts,missing=render(lookup[row['source'],row['originalSHA256']]['raw'])
            if digest(text)!=row['renderedSHA256']:raise ValueError('candidate drift')
            print(json.dumps({**row,'text':text,'hosts':hosts,'missingURL':missing},ensure_ascii=False))
        return
    reviews=json.loads(REVIEWS.read_text());decisions={r['id']:r for r in reviews['reviews']}
    if manifest['preparationSourceSHA256']!=hashlib.sha256(Path(__file__).read_bytes()).hexdigest():
        raise ValueError('preparation implementation changed after reservation')
    if manifest['protocolSHA256']!=hashlib.sha256((ROOT/'tools/transformer-trainer/experiments/signal-generalization-v15-protocol.json').read_bytes()).hexdigest():
        raise ValueError('study protocol changed after reservation')
    if set(decisions)!=set(range(len(manifest['candidates']))):raise ValueError('every candidate needs explicit review')
    kept=defaultdict(list);groups={};seen=set();protected=set(manifest['protectedSignatureSHA256']);lineage=[]
    retirement=RetiredSamples()
    from prepare_approved_signal import quality_reason
    from model_contract import model_labels
    taxonomy=json.loads((ROOT/'packages/taxonomy/taxonomy.json').read_text());valid=set(model_labels({l['id'] for g in taxonomy['groups'] for l in g['leaves']}))
    for candidate in manifest['candidates']:
        decision=decisions[candidate['id']]
        if not decision.get('reason'):raise ValueError('review reason required')
        if decision['label'] is None:continue
        original=lookup[candidate['source'],candidate['originalSHA256']]
        text=decision.get('replacementText') or render(original['raw'])[0]
        original_hosts=set(render(original['raw'])[1]);safe,hosts,_=render(text)
        if safe!=text or not set(hosts).issubset(original_hosts):raise ValueError('unreviewed identity or invented host in replacement')
        row={'text':text,'label':decision['label'],'language':candidate['language'],'source':'public-reviewed-v15:'+candidate['source']}
        if row['label'] not in valid or quality_reason(row) or retirement.reason(row):raise ValueError('invalid reviewed row')
        signatures={digest(k) for k in keys(text,family=True)}
        if signatures&(protected|seen):raise ValueError('reviewed duplicate/protected family')
        seen.update(signatures);group=candidate['groupSHA256'];split=candidate['split']
        if groups.get(group,split)!=split:raise ValueError('group crosses splits')
        groups[group]=split;kept[split].append(row)
        lineage.append({**candidate,'label':row['label'],'textSHA256':digest(text)})
    protocol=json.loads((ROOT/'tools/transformer-trainer/experiments/signal-generalization-v15-protocol.json').read_text())
    for split,minimum,junk_min in [('development',40,10),('final',50,20)]:
        if len(kept[split])<minimum or sum(r['label']=='spam' for r in kept[split])<junk_min:
            raise ValueError('insufficient pre-inference support: '+split)
    outputs={s:ROOT/f'tools/transformer-trainer/Evaluation/signal-public-{s}-v15.ndjson' for s in kept}
    for split,file in outputs.items():
        if file.exists():raise ValueError('refuse to overwrite frozen evaluation')
        file.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in kept[split]))
    result={'schemaVersion':1,'sources':manifest['sources'],'protocolSHA256':manifest['protocolSHA256'],
        'reviewsSHA256':hashlib.sha256(REVIEWS.read_bytes()).hexdigest(),'lineage':lineage,
        'splitCounts':{k:dict(Counter(r['label'] for r in v)) for k,v in kept.items()},
        'filesSHA256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in outputs.values()},
        'reviewMethod':reviews['reviewMethod'],'finalBodiesReviewedForAnnotationBeforeTraining':True,
        'finalPredictionsReadOrScored':False,'rejectedBodiesRetained':False,
        'groupingLimits':'NUS anonymous contributors and public host/template families. Unknown campaign authorship in Mendeley/IMC is not certified independent.'}
    write(ROOT/'tools/apple-trainer/Evaluation/public-generalization-v15.json',result)
    print(json.dumps({'counts':{k:len(v) for k,v in kept.items()},'labels':result['splitCounts'],'finalScored':False},indent=2))


if __name__=='__main__':main()
