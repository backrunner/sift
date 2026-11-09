"""Admission of URL-matched families before head selection or validation."""
import json
from pathlib import Path
from collections import Counter
from approved_signal import ROOT
from author_fusion_v68 import cases
from filter_policy import identity, training_kind
from import_reviewed_public import keys
from prepare_approved_signal import quality_reason
from prepare_enrichment_v16 import suffixes
from prepare_families_v60 import read, sha, write
from public_group_isolation import shingles, similar
from retired_samples import RetiredSamples

NAME = 'signal-fusion-v68'
OUT = ROOT / 'build/signal-fusion-v68-20261102'
EVAL = ROOT / 'tools/transformer-trainer/Evaluation'


def main():
    if (OUT / 'admission.json').exists(): raise ValueError('already admitted')
    OUT.mkdir(parents=True, exist_ok=True)
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(ROOT / 'build/signal-sam-retained-v33-20261029/sam-321/checkpoint', local_files_only=True)
    paths = sorted(set((ROOT / 'tools/apple-trainer/Training').glob('*.ndjson'))
        | set((ROOT / 'tools/apple-trainer/Evaluation').glob('*.ndjson')) | set(EVAL.glob('*.ndjson'))
        | {ROOT / 'build/signal-action-head-v67-20261101/training-pool.ndjson'})
    assert not any(p.name.startswith(NAME) for p in paths)
    old_texts = sorted({r['text'] for p in paths for r in read(p)})
    suffix = suffixes(); suffix.tlds.update(('invalid', 'example', 'test'))
    features = [shingles(t, suffix) for t in old_texts]
    seen = {identity(k) for t in old_texts for k in keys(t, family=True)}
    retired = RetiredSamples(); roles = {'calibration': [], 'validation': []}
    families = set(); hosts = set(); failures = []; review = []
    for role, family, normal, host, variants in cases():
        assert role in roles and family not in families and host not in hosts
        assert len(variants) == 4 and all(len(v) == 3 for v in variants)
        families.add(family); hosts.add(host); group_features = []; group_keys = set()
        for intent, label, variants_by_language in zip(('service', 'ordinary', 'commercial', 'harmful'),
                (normal, '__sift_abstain__', 'promotion', 'spam'), variants, strict=True):
            for lang, body in zip(('zh', 'en', 'ja'), variants_by_language, strict=True):
                assert '://' not in body
                text = body.strip() + ' https://' + host + '/r'
                row = dict(text=text, label=label, language=lang, source=f'authored-reviewed-v68:{family}:{intent}',
                           role=role, familyId=family)
                sig = {identity(k) for k in keys(text, family=True)}; feat = shingles(text, suffix)
                token_count = len(tokenizer(text)['input_ids'])
                reason = quality_reason(row) or retired.reason(row)
                if token_count > 96: reason = 'full-evidence-exceeds-96-tokens'
                if sig & (seen | group_keys): reason = 'historical-or-cross-role-signature-overlap'
                if any(similar(feat, old) for old in features): reason = 'near-historical-or-cross-family-overlap'
                if reason: failures.append(dict(family=family, role=role, intent=intent, language=lang,
                                               reason=reason, tokens=token_count, text=text))
                basis = {'service': 'Explicit existing transaction, credit, setting or requested service; no new purchase solicitation.',
                         'ordinary': 'Personal conversation or general advice without a provider-specific service event.',
                         'commercial': 'Optional new paid service or product; no harmful mechanism.',
                         'harmful': 'Explicit credential/payment-secret exfiltration, remote bank control, gift-card collection, private advance fee or all-funds safe-account coercion.'}[intent]
                row['filterReview'] = dict(kind=training_kind(label), inputForm='sms-text', basis=basis,
                    originalLabelPreserved=True, reviewedTextSHA256=identity(text), fineLabelScored=True)
                roles[role].append(row); group_keys.update(sig); group_features.append(feat)
                review.append(dict(textSHA256=identity(text), family=family, role=role, intent=intent, label=label,
                    language=lang, tokenCount=token_count, reason=basis, accepted=reason is None,
                    observedSMS=False, independentNativeReview=False, predictionsUsedForReview=False))
        seen.update(group_keys); features.extend(group_features)
    if failures:
        path = OUT / f'admission-failed-{1 + len(list(OUT.glob("admission-failed-*.json")))}.json'
        write(path, dict(failures=failures, sourceSHA256=sha(Path(__file__).with_name('author_fusion_v68.py'))))
        print(json.dumps(failures, ensure_ascii=False, indent=2)); raise ValueError('whole admission rejected before inference')
    for role, rows in roles.items():
        assert len(rows) == 72 and len({r['familyId'] for r in rows}) == 6
        with (EVAL / f'{NAME}-{role}.ndjson').open('x') as f:
            for row in rows: f.write(json.dumps(row, ensure_ascii=False) + '\n')
    write(OUT / 'admission.json', dict(review=review,
        roleFiles={r: str((EVAL / f'{NAME}-{r}.ndjson').relative_to(ROOT)) for r in roles},
        roleFilesSHA256={r: sha(EVAL / f'{NAME}-{r}.ndjson') for r in roles},
        historicalFilesSHA256={str(p.relative_to(ROOT)): sha(p) for p in paths},
        sourceSHA256={str(p.relative_to(ROOT)): sha(p) for p in [Path(__file__), Path(__file__).with_name('author_fusion_v68.py')]},
        counts={r: dict(Counter(x['filterReview']['kind'] for x in rows)) for r, rows in roles.items()},
        syntheticRows=144, newTrainingRows=0, sourceIndependentFinal=False,
        reviewScope='Assistant semantic review, full96token visibility and known exact/digit/template/semantic signatures plus trigram Jaccard.65. Same opaque URL across four intents and languages within family. No observed-message or independent native-review claim.',
        releaseEligible=False))
    print('Admitted144 new URL-matched rows:72 calibration,72 validation; no new fitting data.', flush=True)


if __name__ == '__main__': main()
