"""Admit fresh calibration without exposing it to head/gate fitting."""
import json
from pathlib import Path
from approved_signal import ROOT
from author_routing_v71 import cases
from filter_policy import identity,training_kind
from import_reviewed_public import keys
from prepare_approved_signal import quality_reason
from prepare_enrichment_v16 import suffixes
from prepare_families_v60 import read,sha,write
from public_group_isolation import shingles,similar
from retired_samples import RetiredSamples

OUT=ROOT/'build/signal-expert-routing-v71-20261102'
CALIBRATION=ROOT/'tools/transformer-trainer/Evaluation/signal-expert-routing-v71r1-calibration.ndjson'
TRAINING=ROOT/'build/signal-correction-v69-20261102/training-pool.ndjson'


def main():
    from transformers import AutoTokenizer
    assert not (OUT/'admission.json').exists() and not CALIBRATION.exists()
    tokenizer=AutoTokenizer.from_pretrained(ROOT/'build/signal-sam-retained-v33-20261029/sam-321/checkpoint',local_files_only=True)
    taxonomy=json.loads((ROOT/'packages/taxonomy/taxonomy.json').read_text())
    valid_labels={leaf['id'] for group in taxonomy['groups'] for leaf in group['leaves']}|{'__sift_abstain__'}
    paths=sorted(set((ROOT/'tools/apple-trainer/Training').glob('*.ndjson'))
        |set((ROOT/'tools/apple-trainer/Evaluation').glob('*.ndjson'))
        |set((ROOT/'tools/transformer-trainer/Evaluation').glob('*.ndjson'))|{TRAINING})
    texts=sorted({r['text'] for p in paths for r in read(p)})
    suffix=suffixes();suffix.tlds.update(('invalid','example','test'))
    known={identity(k) for t in texts for k in keys(t,family=True)}
    features=[shingles(t,suffix) for t in texts]
    retired=RetiredSamples();rows=[];review=[];failures=[];families=set();hosts=set()
    for family,normal,host,variants in cases():
        assert family not in families and host not in hosts
        families.add(family);hosts.add(host);group_keys=set();group_features=[]
        for intent,label,translations in zip(('service','ordinary','commercial','harmful'),
                (normal,'__sift_abstain__','promotion','spam'),variants,strict=True):
            for lang,body in zip(('zh','en','ja'),translations,strict=True):
                assert '://' not in body
                text=body.strip()+' https://'+host+'/r'
                row=dict(text=text,label=label,language=lang,source=f'authored-reviewed-v71:{family}:{intent}',familyId=family,role='calibration')
                if label not in valid_labels:raise ValueError('unknown taxonomy label: '+label)
                sig={identity(k) for k in keys(text,family=True)};feat=shingles(text,suffix)
                tokens=len(tokenizer(text)['input_ids']);reason=quality_reason(row) or retired.reason(row)
                if tokens>96:reason='evidence-exceeds96tokens'
                if sig&(known|group_keys):reason='known-or-cross-family-signature-overlap'
                if any(similar(feat,old) for old in features):reason='near-known-or-cross-family-overlap'
                basis={'service':'Explicit completed or accepted user-requested service, with no optional new purchase.',
                    'ordinary':'Personal discussion or preparation; explicitly no completed service event.',
                    'commercial':'Optional new paid service or product; no harmful collection mechanism.',
                    'harmful':'Explicit bank-code disclosure, personal advance fee, gift-card codes, all-funds safe-account coercion or remote banking control.'}[intent]
                row['filterReview']=dict(kind=training_kind(label),inputForm='sms-text',basis=basis,
                    originalLabelPreserved=True,reviewedTextSHA256=identity(text),fineLabelScored=True)
                record=dict(textSHA256=identity(text),family=family,language=lang,intent=intent,tokens=tokens,
                    accepted=reason is None,reason=reason or basis,observedSMS=False,independentNativeReview=False)
                if reason:failures.append({**record,'text':text})
                review.append(record);rows.append(row);group_keys.update(sig);group_features.append(feat)
        known.update(group_keys);features.extend(group_features)
    if failures:
        write(OUT/f'admission-failed-{len(list(OUT.glob("admission-failed-*.json")))+1}.json',dict(failures=failures))
        raise ValueError(json.dumps(failures,ensure_ascii=False))
    assert len(rows)==72 and len(families)==6
    with CALIBRATION.open('x') as f:
        for r in rows:f.write(json.dumps(r,ensure_ascii=False)+'\n')
    write(OUT/'admission.json',dict(calibration=str(CALIBRATION.relative_to(ROOT)),calibrationSHA256=sha(CALIBRATION),
        review=review,newTrainingRows=0,newCalibrationRows=72,sourceIndependentFinal=False,
        historicalFilesSHA256={str(p.relative_to(ROOT)):sha(p) for p in paths},
        sourceSHA256={str(p.relative_to(ROOT)):sha(p) for p in [Path(__file__),Path(__file__).with_name('author_routing_v71.py')]},
        scope='Assistant-reviewed synthetic family calibration; exact/digit/template/semantic and trigram checks, all full96token-visible; no observed SMS/native certification claim.'))
    print('Admitted72 new calibration rows; fitting pool and reserved validation untouched.',flush=True)


if __name__=='__main__':main()
