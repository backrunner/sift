"""Reserve and review new public TRAINING groups; never use predictions as gold."""
import argparse
import ast
from collections import Counter, defaultdict
import csv
import hashlib
import html
import json
from pathlib import Path
import re

import prepare_public_generalization as old
from import_reviewed_public import keys
from prepare_approved_signal import quality_reason
from public_group_isolation import Groups, Suffixes, family, links, shingles, similar
from retired_samples import RetiredSamples

ROOT = old.ROOT
OUT = ROOT / 'build/signal-enrichment-v16-20261028'
PROTOCOL = ROOT / 'tools/transformer-trainer/experiments/signal-enrichment-v16-protocol.json'
RESERVED = OUT / 'public-candidates.json'
REVIEWS = ROOT / 'tools/apple-trainer/Training/public-sms-v16-reviews.json'
WSPR = ROOT / 'build/public-source-audit-20261028-wspr'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    return [json.loads(l) for l in Path(path).read_text().splitlines() if l]


def suffixes():
    receipt = json.loads((OUT / 'suffix-source.json').read_text())
    path = OUT / 'public_suffix_list.dat'
    if sha(path) != receipt['sha256']:
        raise ValueError('suffix snapshot drift')
    return Suffixes(path.read_text())


def records():
    sources, rows = old.source_records()
    spec = json.loads((WSPR / 'source.json').read_text())
    for name, digest in spec['files'].items():
        if sha(WSPR / name) != digest:
            raise ValueError('WSPR source drift')
    sources['wspr-sp24'] = spec
    # No destination number, object ID or raw numeric ID is copied into rows.
    for r in csv.DictReader((WSPR / 'phishing_messages.csv').open()):
        text = old.normalize(r['message'])
        rows.append({'source': 'wspr-sp24', 'raw': text, 'originalSHA256': old.digest(text),
                     'language': 'en', 'contributor': None, 'sourceLabel': 'reported-phishing', 'translation': ''})
    return sources, rows


def render(text, suffix):
    text = html.unescape(text).replace('\\n', ' ').replace('\\r', ' ')
    if re.search(r'#(?:URL|OTP|ID)\b|<[A-Z_#]+>', text):
        raise ValueError('missing-source-evidence')
    # Only strip tracking paths. Retain original public host for intent review.
    for start, end, host in reversed(links(text, suffix)):
        if re.search(r'\d{7,}|[a-z0-9]{25}', host, re.I):
            raise ValueError('host-identifier')
        text = text[:start] + 'https://' + host + '/review' + text[end:]
    if re.search(r'[\w.+-]+@[\w.-]+\.[a-z]{2,}', text, re.I):
        raise ValueError('email-identifier')
    for m in re.finditer(r'(?<!\w)\+?\d[\d ()-]{5,}\d(?!\w)', text):
        if sum(c.isdigit() for c in m[0]) >= 7:
            raise ValueError('unreviewed-contact-or-identifier')
    text = old.normalize(text)
    if not 18 <= len(text) <= 450:
        raise ValueError('short-or-long')
    return text


def prior_candidates():
    known = old.previous_reviews()
    for fn in ['public-candidates.json', 'public-candidates-initial.json', 'public-wspr-candidates.json']:
        for c in json.loads((old.OUT / fn).read_text())['candidates']:
            known[c['source']].add(c['originalSHA256'])
    return known


def protected_paths():
    paths = [ROOT / 'tools/apple-trainer/Training/signal-reviewed-v13.ndjson',
             ROOT / 'build/signal-corpus-review-20261027/all-eval-reviewed.ndjson',
             ROOT / 'build/signal-generalization-20261027/final.ndjson',
             ROOT / 'build/signal-corpus-review-20261027/vietnamese-official-test-families.ndjson']
    paths += sorted((ROOT / 'tools/transformer-trainer/Evaluation').glob('*.ndjson'))
    return list(dict.fromkeys(paths))


def group_keys(text, suffix, contributor=None):
    result = ['family:' + old.digest(family(text, suffix))]
    result += ['host:' + suffix.registrable(h) for _, _, h in links(text, suffix)]
    if contributor:
        result.append('contributor:' + old.digest(contributor))
    return result


def reserve():
    if RESERVED.exists():
        raise ValueError('candidate split already reserved')
    suffix = suffixes(); sources, rows = records(); groups = Groups()
    known = prior_candidates(); tainted = []; protected_texts = []
    contract = json.loads((ROOT / 'tools/apple-trainer/Training/signal-generalization-v15.json').read_text())
    protected = set(contract['protectedSignatureSHA256'])
    frozen_rows = {}
    for path in protected_paths():
        rs = read(path); frozen_rows[str(path.relative_to(ROOT))] = rs
        for r in rs:
            protected_texts.append(r['text'])
            protected.update(old.digest(k) for k in keys(r['text'], family=True))
            tainted.append(groups.union(group_keys(r['text'], suffix)))
    for r in rows:
        ks = group_keys(r['raw'], suffix, r['contributor'])
        if r['translation']:
            ks += group_keys(r['translation'], suffix)
        r['_node'] = groups.union(ks)
        if r['originalSHA256'] in known[r['source']]:
            tainted.append(r['_node'])
    rejected = json.loads((old.OUT / 'public-wspr-template-rejected.json').read_text())['candidateManifest']
    rejected_hashes = {c['originalSHA256'] for c in rejected['candidates']}
    campaign_rows = list(csv.DictReader((WSPR / 'phishing_campaigns.csv').open()))
    for c in campaign_rows:
        # Actual URLs, not campaignID/messageID equality, connect source rows.
        ks = group_keys(c['message'], suffix)
        for url in ast.literal_eval(c['urls']):
            ks += ['host:' + suffix.registrable(h) for _, _, h in links(url, suffix)]
        node = groups.union(ks)
        if old.digest(old.normalize(c['message'])) in rejected_hashes:
            tainted.append(node)
    tainted = {groups.find(k) for k in tainted}
    # Corrective evidence for the already-frozen v15 data; never change its gold.
    oldsets = {}
    for name, path in [('training', 'tools/apple-trainer/Training/signal-reviewed-v13.ndjson'),
                       ('development', 'tools/transformer-trainer/Evaluation/signal-public-development-v15.ndjson'),
                       ('final', 'tools/transformer-trainer/Evaluation/signal-public-final-v15.ndjson')]:
        oldsets[name] = [groups.find(group_keys(r['text'], suffix)[0]) for r in frozen_rows[path]]
    pairs = {}
    for a, b in [('training','development'), ('training','final'), ('development','final')]:
        shared = set(oldsets[a]) & set(oldsets[b])
        pairs[a + '/' + b] = {'sharedComponents': len(shared), a+'Rows':sum(x in shared for x in oldsets[a]), b+'Rows':sum(x in shared for x in oldsets[b])}
    raw_by_id = {r['messageID']:r for r in csv.DictReader((WSPR / 'phishing_messages.csv').open())}
    matching = sum(any(u and u in raw_by_id[c['campaignID']]['message'] for u in ast.literal_eval(c['urls'])) for c in campaign_rows)
    audit = {'invalidIDJoin': True, 'campaignCount':len(campaign_rows), 'sameIDURLMatches':matching,
             'correctedGrouping':pairs, 'v15GoldAndModelScoresUnchanged':True,
             'interpretation':'Shared infrastructure is conservative evidence of non-independent source groups, not proof of identical messages. v15 final must not be called a blind independent acceptance set if any overlap is found.',
             'sourceFilesSHA256':sources['wspr-sp24']['files']}
    old.write(OUT / 'v15-corrective-audit.json', audit)
    features = [shingles(t, suffix) for t in dict.fromkeys(protected_texts)]
    caps = {('wspr-sp24','en'): (100,40), ('nus-en','en'):(45,18), ('nus-zh','zh'):(65,24),
            ('mendeley-2022','en'):(35,16), ('imc25','en'):(35,16), ('imc25','ja'):(35,16), ('imc25','zh'):(25,12)}
    counts = Counter(); excluded = Counter(); selected=[]; seen_groups=set()
    for r in sorted(rows, key=lambda r:old.digest('v16-candidate:'+r['originalSHA256'])):
        bucket=(r['source'],r['language']); cap=caps.get(bucket)
        if not cap: continue
        group = groups.find(r['_node'])
        split = 'development' if int(old.digest('v16-split:'+group),16)%4==0 else 'train'
        if counts[bucket,split] >= cap[split=='development']:continue
        if group in tainted or group in seen_groups:
            excluded['exposed-or-already-selected-component']+=1;continue
        if r['source'].startswith('nus-') and not old.valid_contributor(r['contributor']):
            excluded['missing-contributor']+=1;continue
        try: text=render(r['raw'],suffix)
        except ValueError as e:excluded[str(e)]+=1;continue
        if r['source']=='wspr-sp24' and (not re.search(r'\b(?:your|you|please|delivery|account|customer|payment|parcel|package)\b',text,re.I) or re.search(r'[\u0400-\u052f\u3040-\u30ff\u3400-\u9fff]',text)):
            excluded['not-supported-english-candidate']+=1;continue
        sig={old.digest(k) for k in keys(text,family=True)}
        if sig & protected:excluded['protected-signature']+=1;continue
        feat=shingles(text,suffix)
        if any(similar(feat,f) for f in features):excluded['near-protected-or-selected']+=1;continue
        row={'text':text,'label':'__sift_abstain__','source':'public-reviewed-v16:'+r['source'],'language':r['language']}
        if quality_reason(row) or RetiredSamples().reason(row):excluded['quality-or-retirement']+=1;continue
        selected.append({'id':len(selected),'source':r['source'],'language':r['language'],
                         'originalSHA256':r['originalSHA256'],'renderedSHA256':old.digest(text),
                         'groupSHA256':old.digest(group),'sourceLabel':r['sourceLabel'],'split':split})
        features.append(feat);protected.update(sig);seen_groups.add(group);counts[bucket,split]+=1
    old.write(RESERVED, {'schemaVersion':1,'sources':sources,'candidates':selected,'exclusions':dict(excluded),
        'scriptSHA256':sha(Path(__file__)),'groupImplementationSHA256':sha(Path(__file__).with_name('public_group_isolation.py')),
        'protocolSHA256':sha(PROTOCOL),'suffixSHA256':sha(OUT/'public_suffix_list.dat'),
        'protectedInputsSHA256':{str(p.relative_to(ROOT)):sha(p) for p in protected_paths()},
        'sourceGroupPolicy':'Public hosts + URL-masked families + NUS contributors connected over full source pool; all exposed groups excluded, near-similarity threshold .65.',
        'reviewMethod':'Every candidate requires explicit content/intent decision before inference; no raw identity fields materialized.'})
    print(json.dumps({'candidates':len(selected),'counts':{str(k):v for k,v in counts.items()},'exclusions':excluded,'v15Audit':audit},indent=2))


def candidate_bodies():
    manifest=json.loads(RESERVED.read_text());_,rows=records()
    raw={(r['source'],r['originalSHA256']):r['raw'] for r in rows};suffix=suffixes()
    for c in manifest['candidates']:
        text=render(raw[c['source'],c['originalSHA256']],suffix)
        if old.digest(text)!=c['renderedSHA256']:raise ValueError('candidate drift')
        yield c,text


def materialize_public():
    m=json.loads(RESERVED.read_text())
    for expected,path in [(m['scriptSHA256'],Path(__file__)),(m['groupImplementationSHA256'],Path(__file__).with_name('public_group_isolation.py')),(m['protocolSHA256'],PROTOCOL)]:
        if sha(path)!=expected:raise ValueError('reserved implementation/protocol drift')
    for p,h in m['protectedInputsSHA256'].items():
        if sha(ROOT/p)!=h:raise ValueError('protected input drift')
    reviews=json.loads(REVIEWS.read_text());decisions={d['id']:d for d in reviews['reviews']}
    if set(decisions)!=set(range(len(m['candidates']))):raise ValueError('incomplete reviews')
    kept=defaultdict(list);lineage=[]
    for c,text in candidate_bodies():
        r=decisions[c['id']]
        if not r.get('reason'):raise ValueError('missing review reason')
        if r['label'] is None:continue
        # Public samples are either accepted as rendered or rejected; no invented evidence.
        row={'text':text,'label':r['label'],'language':c['language'],'source':'public-reviewed-v16:'+c['source']}
        if quality_reason(row) or RetiredSamples().reason(row):raise ValueError('bad accepted public row')
        kept[c['split']].append(row);lineage.append({**c,'label':r['label'],'textSHA256':old.digest(text)})
    for split,rs in kept.items():
        p=OUT/('public-'+split+'.ndjson')
        if p.exists():raise ValueError('refuse overwrite')
        p.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rs))
    old.write(OUT/'public-lineage.json',{'lineage':lineage,'reservedSHA256':sha(RESERVED),'reviewsSHA256':sha(REVIEWS)})
    print(json.dumps({s:dict(Counter(r['label'] for r in rs)) for s,rs in kept.items()},ensure_ascii=False,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('stage',choices=['reserve','view','materialize']);parser.add_argument('--start',type=int,default=0);parser.add_argument('--end',type=int,default=50);args=parser.parse_args()
    if args.stage=='reserve':reserve()
    elif args.stage=='materialize':materialize_public()
    else:
        for c,t in candidate_bodies():
            if args.start<=c['id']<args.end:print(json.dumps({**c,'text':t},ensure_ascii=False))
