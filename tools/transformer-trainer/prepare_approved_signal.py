"""Materialize a standalone approved corpus; legacy quarantined inputs are not dependencies."""
import argparse
from collections import Counter,defaultdict
import hashlib
import json
from pathlib import Path
import re

from audit_generalization import training_policy_findings
from import_reviewed_public import keys
from model_contract import model_labels
from retired_samples import RetiredSamples


def read(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def quality_reason(row):
    text=row['text'].replace('\\n','\n').replace('\\r','\r')
    if '様さん' in text:
        return 'duplicated-japanese-honorific'
    if row.get('language')=='ja' and row.get('source','').startswith('synthetic:clean-v8:') and re.search(r'\d+\.\d{2}円',text):
        return 'generated-yen-amount-has-cents'
    if row['label']=='life.utility' and re.search(r'(?:宽带|broadband|インターネット).*?(?:账单|bill|請求)',text,re.I):
        return 'broadband-billing-belongs-to-carrier'
    if re.search(r'\{\{|<\s*(?:IP_ADDRESS|EMAIL_ADDRESS|PHONE|NAME|ADDRESS)\s*>|\bP0{7,}\b',text):
        return 'unrendered-public-placeholder'
    if re.search(r'https?:(?!//)|https?://(?:https?[:/]|\s|$)',text,re.I):
        return 'malformed-public-url'
    if re.search(r'[\u3040-\u30ff\u3400-\u9fff]',text) and re.search(r'\btomorrow\b',text,re.I):
        return 'wrong-language-anonymizer-role'
    if re.search(r'(?:call|phone|on|hotline|consult|咨询)\s+(?:us\s+)?(?:on\s+)?tomorrow(?:[.!。]|$)',text,re.I):
        return 'ambiguous-phone-time-anonymizer-role'
    if re.search(r'(?:https?://|\bwww\.)\s*$|#\d{6}\s*$',text):
        return 'truncated-url-or-generator-padding'
    if row['label']=='finance.bank' and re.search(r'account .* was debited .* at \d|Debit card ending .* was used for|账户完成扣款|完成一笔支出|网银支出|口座から.*引き落とされました',text,re.I):
        return 'underspecified-bank-fund-direction'
    return None


def prepare(base,core,out):
    if out.exists():raise ValueError('output directory exists')
    retirement=RetiredSamples()
    protected_paths=[base/'development.ndjson',Path('build/signal-corpus-review-20261027/all-eval-reviewed.ndjson'),
        Path('build/signal-generalization-20261027/final.ndjson'),
        Path('build/signal-corpus-review-20261027/vietnamese-official-test-families.ndjson')]
    protected=set().union(*(keys(r['text'],family=True) for p in protected_paths for r in read(p)))
    kept=[];seen=set();counts=Counter();deleted=[]
    staged=[]
    for row in read(base/'train.ndjson'):
        source=row['source']
        if source.startswith(('public-reviewed-','signal-reviewed-v2:','augmentation:semantic:signal-v65:')) or source=='conversation-training.ndjson':
            staged.append(row)
        else:counts['retired-legacy-or-uncertified-source']+=1
    staged.extend(read(core))
    staged.extend(read(Path('tools/apple-trainer/Training/signal-v8-reviewed-service-coverage.ndjson')))
    # Reviewed source and semantic scenarios take precedence over generation.
    families=Counter();template_counts=Counter()
    for row in staged:
        reason=retirement.reason(row) or quality_reason(row)
        signatures=keys(row['text'],family=True)
        if signatures&protected:reason='protected-holdout-family'
        if not reason and signatures&seen:reason='duplicate-family'
        if not reason and row['source'].startswith('synthetic:clean-v8:'):
            bucket=(row['label'],row['language'])
            if template_counts[row['source']]>=2:reason='generated-template-cap'
            elif families[bucket]>=16:reason='generated-label-language-cap'
            else:
                families[bucket]+=1;template_counts[row['source']]+=1
        if reason:
            counts[reason]+=1
            deleted.append({'textSHA256':hashlib.sha256(row['text'].encode()).hexdigest(),
                'source':row['source'],'label':row['label'],'reason':reason})
            continue
        kept.append(row);seen.update(signatures)
    taxonomy=json.loads(Path('packages/taxonomy/taxonomy.json').read_text())
    labels=model_labels({l['id'] for g in taxonomy['groups'] for l in g['leaves']})
    coverage=Counter((r['label'],r.get('language')) for r in kept)
    gaps=[(l,lang,coverage[l,lang]) for l in sorted(labels) for lang in ('zh','en','ja') if coverage[l,lang]<10]
    if training_policy_findings(kept):raise ValueError('fund direction audit failed')
    out.mkdir(parents=True)
    (out/'train.ndjson').write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in kept))
    (out/'development.ndjson').write_bytes((base/'development.ndjson').read_bytes())
    report={'schemaVersion':1,'trainingCount':len(kept),'counts':counts,'removed':deleted,
        'sourceCounts':Counter(r['source'].split(':')[0] for r in kept),'coverageGaps':gaps,
        'method':'Content/provenance and frozen-family rules, before continuation; no candidate predictions.',
        'reviewMethod':'AI-assisted content and seed-family review, not independent human/native-speaker certification.',
        'strictAuditPassed':not gaps,'protectedInputsSHA256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in protected_paths}}
    (out/'quality-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    return {k:report[k] for k in ('trainingCount','counts','coverageGaps','sourceCounts')}


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base',type=Path,default=Path('build/signal-source-balanced-20261028'))
    p.add_argument('--core',type=Path,default=Path('build/signal-clean-v8-core.ndjson'))
    p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();print(json.dumps(prepare(a.base,a.core,a.out),ensure_ascii=False,indent=2))
