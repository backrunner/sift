"""Validate the standalone approved training contract before using model compute."""
from collections import Counter
import hashlib
import json
from pathlib import Path

from import_reviewed_public import keys
from model_contract import model_labels
from prepare_approved_signal import quality_reason
from retired_samples import RetiredSamples


ROOT=Path(__file__).resolve().parents[2]
DEFAULT=ROOT/'tools/apple-trainer/Training/signal-reviewed-v13.json'


def verify(path=DEFAULT):
    manifest=json.loads(Path(path).read_text())
    if manifest.get('kind')!='approved-signal-corpus':raise ValueError('unsupported approved manifest')
    for relative,digest in manifest['filesSHA256'].items():
        file=(ROOT/relative).resolve()
        if not file.is_relative_to(ROOT) or hashlib.sha256(file.read_bytes()).hexdigest()!=digest:
            raise ValueError('approved corpus dependency drift: '+relative)
    rows=[json.loads(l) for l in (ROOT/manifest['training']).read_text().splitlines() if l]
    if len(rows)!=manifest['trainingCount']:raise ValueError('approved row count drift')
    protected=set(manifest['protectedSignatureSHA256']);seen=set();template_counts=Counter()
    retirement=RetiredSamples();coverage=Counter()
    for row in rows:
        if retirement.reason(row) or quality_reason(row):raise ValueError('retired or malformed approved row')
        signatures={hashlib.sha256(k.encode()).hexdigest() for k in keys(row['text'],family=True)}
        if signatures&(protected|seen):raise ValueError('approved family leakage or duplicate')
        seen.update(signatures);coverage[row['label'],row['language']]+=1
        if row['source'].startswith('synthetic:clean-v8:'):template_counts[row['source']]+=1
    if any(n>manifest['generatedTemplateCap'] for n in template_counts.values()):
        raise ValueError('generated template concentration exceeds approved cap')
    taxonomy=json.loads((ROOT/'packages/taxonomy/taxonomy.json').read_text())
    labels=model_labels({l['id'] for g in taxonomy['groups'] for l in g['leaves']})
    if any(coverage[l,lang]<10 for l in labels for lang in ('zh','en','ja')):
        raise ValueError('approved core-language coverage gap')
    if review_path:=manifest.get('junkEvidenceReview'):
        from junk_evidence import validate_junk_evidence
        if review_path not in manifest['filesSHA256']:
            raise ValueError('junk evidence review must be hash-pinned')
        review=json.loads((ROOT/review_path).read_text())
        for source in review['sourceEvidence'].values():
            if manifest['filesSHA256'].get(source['file'])!=source['sha256']:
                raise ValueError('junk source evidence must be hash-pinned')
        validate_junk_evidence(rows,review)
    if review_path:=manifest.get('urlContrastReview'):
        from url_contrast import validate_url_review
        if review_path not in manifest['filesSHA256']:
            raise ValueError('URL contrast review must be hash-pinned')
        validate_url_review(rows,json.loads((ROOT/review_path).read_text()))
    if review_path := manifest.get('filterTargetReview'):
        from filter_policy import validate_targets
        if review_path not in manifest['filesSHA256']:
            raise ValueError('filter target review must be hash-pinned')
        spec = json.loads((ROOT/review_path).read_text())
        if spec['trainingSHA256'] != manifest['filesSHA256'][manifest['training']]:
            raise ValueError('filter target input hash drift')
        if manifest.get('trainingEntrypoint') != 'tools/transformer-trainer/train_filter_policy_v47.py':
            raise ValueError('filter target corpus requires the policy training entry point')
        validate_targets(rows, spec)
    return manifest


if __name__=='__main__':
    m=verify();print(json.dumps({'trainingCount':m['trainingCount'],'developmentCount':m['developmentCount'],
        'generatedTemplateCap':m['generatedTemplateCap'],'verified':True}))
