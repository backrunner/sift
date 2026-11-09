"""Review and isolate v96 zh and ja families before any model sees them."""
from collections import Counter
import json
from pathlib import Path

from approved_signal import ROOT
from author_cjk_v96 import cases
from filter_policy import identity, training_kind
from import_reviewed_public import keys
from prepare_approved_signal import quality_reason
from prepare_enrichment_v16 import suffixes
from prepare_families_v60 import read, sha, write, rows_file
from public_group_isolation import shingles, similar
from retired_samples import RetiredSamples

OUT = ROOT / 'build/signal-cjk-v96-20261104'
LANGUAGES = ('zh', 'ja')
DOMAINS = dict(zh='cn', ja='jp')
EVIDENCE = ('build/signal-fine-v81-20261102', 'build/signal-real-v90-20261103', 'build/signal-real-v95-20261104', 'build/signal-contrast-v92-20261104', 'build/signal-validation-v94-20261104')
BASIS = {'spam': 'Visible malicious clause: a fee, card, credential or code request, or transfer demand, not a signature or link alone.',
         'promotion': 'New optional offer; no harmful collection mechanism.', 'carrier.promotion': 'Carrier-owned optional offer.',
         '__sift_abstain__': 'Personal conversation with no service event.'}


def main():
    from transformers import AutoTokenizer
    assert not (OUT / 'admission.json').exists(); OUT.mkdir(exist_ok=True)
    paths = set()
    for folder in ('tools/apple-trainer/Training', 'tools/apple-trainer/Evaluation', 'tools/transformer-trainer/Evaluation', *EVIDENCE):
        paths.update((ROOT / folder).glob('*.ndjson'))
    texts = sorted({r['text'] for p in paths for r in read(p) if 'text' in r})
    known = {identity(k) for t in texts for k in keys(t, family=True)}
    suffix = suffixes(); suffix.tlds.update(('invalid', 'example', 'test')); features = [shingles(t, suffix) for t in texts]
    tokenizer = AutoTokenizer.from_pretrained(ROOT / 'build/signal-sam-retained-v33-20261029/sam-321/checkpoint', local_files_only=True)
    taxonomy = json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text())
    labels = {l['id'] for g in taxonomy['groups'] for l in g['leaves']} | {'__sift_abstain__'}
    retired = RetiredSamples(); rows = []; failures = []; ledger = []
    for role, family, boundary, host, events in cases():
        family_keys = set(); added = []; family_texts = []
        for label, *bodies in events:
            assert label in labels, label
            for language, body in zip(LANGUAGES, bodies, strict=True):
                text = body + (f' https://{host}.{DOMAINS[language]}/n' if host else '')
                row = dict(text=text, label=label, language=language, familyId=family, boundary=boundary, source=f'authored-reviewed-v96:{family}', role=role)
                row['filterReview'] = dict(kind=training_kind(label), inputForm='sms-text', fineLabelScored=True, originalLabelPreserved=True, reviewedTextSHA256=identity(text),
                    basis=BASIS.get(label, 'Service event under the taxonomy rubric; a signature, link or sign-in request alone does not make it harmful.'))
                reasons = [r for r in (quality_reason(row), retired.reason(row)) if r]
                signature = {identity(k) for k in keys(text, family=True)}; feature = shingles(text, suffix)
                tokens = len(tokenizer(text)['input_ids'])
                if tokens > 96: reasons.append('beyond-96-token-input')
                if signature & (known | family_keys): reasons.append('signature-overlap')
                near = [texts[i] for i, f in enumerate(features) if similar(feature, f)]
                if near: reasons.append('trigram-overlap')
                item = dict(textSHA256=identity(text), label=label, language=language, familyId=family, role=role, tokens=tokens, reasons=reasons, observedSMS=False, independentNativeReview=False)
                if reasons: failures.append(dict(item, text=text, neighbors=near[:2]))
                ledger.append(item); rows.append(row); family_keys |= signature; added.append(feature); family_texts.append(text)
        known |= family_keys; features.extend(added); texts.extend(family_texts)
    if failures:
        write(OUT / f'admission-failed-{len(list(OUT.glob("admission-failed-*.json"))) + 1}.json', dict(failures=failures))
        for f in failures: print(f['reasons'], f['text'], '<<', f['neighbors'])
        raise ValueError(f'{len(failures)} rows failed before any inference')
    train = [r for r in rows if r['role'] == 'training']; development = [r for r in rows if r['role'] == 'development']
    rows_file(OUT / 'new-training.ndjson', train); rows_file(OUT / 'development.ndjson', development)
    write(OUT / 'admission.json', dict(newTrainingRows=len(train), developmentRows=len(development), review=ledger, stage='pre-inference',
        byKind=dict(Counter(r['filterReview']['kind'] for r in train)), byLanguage=dict(Counter(r['language'] for r in train)),
        scope='Assistant-authored zh and ja synthetic families with brand-style signatures and fictional hosts; no native certification; not received messages.',
        filesSHA256={str(p.relative_to(ROOT)): sha(p) for p in sorted(paths | {Path(__file__), Path(__file__).with_name('author_cjk_v96.py'), OUT / 'new-training.ndjson', OUT / 'development.ndjson'})}))
    print('admitted', len(train), 'training', len(development), 'development', flush=True)


if __name__ == '__main__': main()
