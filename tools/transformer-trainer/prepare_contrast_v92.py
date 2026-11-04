"""Review and isolate v92 contrast families before any model sees them."""
from collections import Counter
import json
from pathlib import Path

from approved_signal import ROOT
from author_contrast_v92 import cases
from filter_policy import identity, training_kind
from import_reviewed_public import keys
from prepare_approved_signal import quality_reason
from prepare_enrichment_v16 import suffixes
from prepare_families_v60 import read, sha, write, rows_file
from public_group_isolation import shingles, similar
from retired_samples import RetiredSamples

OUT = ROOT / 'build/signal-contrast-v92-20261104'
TRAINING = ROOT / 'build/signal-fine-v85-20261103/training-quality-next.ndjson'
EVIDENCE = ('build/signal-fine-v81-20261102', 'build/signal-real-v90-20261103')
BASIS = {'spam': 'Visible malicious clause: a fee, card, credential or code request, or transfer demand, not the link alone.',
         'promotion': 'New optional offer; no harmful collection mechanism.', 'carrier.promotion': 'Carrier-owned optional offer.',
         '__sift_abstain__': 'Personal conversation with no service event.'}
LANGUAGES = ('zh', 'en', 'ja')


def known_texts():
    paths = {TRAINING}
    for folder in ('tools/apple-trainer/Training', 'tools/apple-trainer/Evaluation', 'tools/transformer-trainer/Evaluation', *EVIDENCE):
        paths.update((ROOT / folder).glob('*.ndjson'))
    return paths, sorted({r['text'] for p in paths for r in read(p) if 'text' in r})


def staged(tokenizer, labels, suffix, texts):
    """Yield every row with its rejection reasons; nothing here can read a model output."""
    known = {identity(k) for t in texts for k in keys(t, family=True)}
    features = [shingles(t, suffix) for t in texts]; retired = RetiredSamples(); hosts = set()
    for role, family, boundary, host, events in cases():
        assert host is None or host not in hosts
        hosts.add(host); signatures = set(); added = []; staged_texts = []
        for label, *bodies in events:
            assert label in labels, label
            for language, body in zip(LANGUAGES, bodies, strict=True):
                assert '://' not in body
                text = body + (f' https://{host}.invalid/r' if host else '')
                row = dict(text=text, label=label, language=language, familyId=family, boundary=boundary,
                           source=f'authored-reviewed-v92:{family}', role=role)
                kind = training_kind(label)
                row['filterReview'] = dict(kind=kind, inputForm='sms-text', basis=BASIS.get(label, 'Service event under the taxonomy rubric; a link or sign-in request alone does not make it harmful.'),
                    fineLabelScored=True, originalLabelPreserved=True, reviewedTextSHA256=identity(text))
                signature = {identity(k) for k in keys(text, family=True)}; feature = shingles(text, suffix)
                tokens = len(tokenizer(text)['input_ids'])
                reasons = [r for r in (quality_reason(row), retired.reason(row)) if r]
                if tokens > 96: reasons.append('beyond-96-token-input')
                if signature & (known | signatures): reasons.append('signature-overlap')
                near = [texts[i] for i, f in enumerate(features) if similar(feature, f)]
                if near: reasons.append('trigram-overlap')
                signatures.update(signature); added.append(feature); staged_texts.append(text)
                yield row, tokens, reasons, near[:2]
        known.update(signatures); features.extend(added); texts.extend(staged_texts)


def main():
    from transformers import AutoTokenizer
    assert not (OUT / 'admission.json').exists(); OUT.mkdir(exist_ok=True)
    paths, texts = known_texts()
    tokenizer = AutoTokenizer.from_pretrained(ROOT / 'build/signal-sam-retained-v33-20261029/sam-321/checkpoint', local_files_only=True)
    taxonomy = json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text())
    labels = {l['id'] for g in taxonomy['groups'] for l in g['leaves']} | {'__sift_abstain__'}
    suffix = suffixes(); suffix.tlds.update(('invalid', 'example', 'test'))
    rows = []; ledger = []; failures = []
    for row, tokens, reasons, near in staged(tokenizer, labels, suffix, texts):
        item = dict(textSHA256=identity(row['text']), label=row['label'], language=row['language'], familyId=row['familyId'], role=row['role'],
                    boundary=row['boundary'], tokens=tokens, reasons=reasons, observedSMS=False, independentNativeReview=False)
        if reasons: failures.append(dict(item, text=row['text'], neighbors=near))
        ledger.append(item); rows.append(row)
    if failures:
        write(OUT / f'admission-failed-{len(list(OUT.glob("admission-failed-*.json"))) + 1}.json', dict(failures=failures))
        print(json.dumps(failures, ensure_ascii=False, indent=1)); raise ValueError(f'{len(failures)} rows failed before any inference')
    train = [r for r in rows if r['role'] == 'training']; development = [r for r in rows if r['role'] == 'development']
    assert not {r['familyId'] for r in train} & {r['familyId'] for r in development}
    assert all(Counter(r['language'] for r in part) == dict.fromkeys(LANGUAGES, len(part) // 3) for part in (train, development))
    rows_file(OUT / 'new-training.ndjson', train); rows_file(OUT / 'development.ndjson', development)
    rows_file(OUT / 'training.ndjson', read(TRAINING) + train)
    write(OUT / 'admission.json', dict(newTrainingRows=len(train), developmentRows=len(development), review=ledger, stage='pre-inference',
        byKind=dict(Counter(r['filterReview']['kind'] for r in train)), byBoundary=dict(Counter(r['boundary'] for r in train)),
        scope='Assistant-authored synthetic contrast families, no native-speaker certification. Development families are disjoint in topic and never trained.',
        filesSHA256={str(p.relative_to(ROOT)): sha(p) for p in sorted(paths | {Path(__file__), Path(__file__).with_name('author_contrast_v92.py'), OUT / 'training.ndjson', OUT / 'new-training.ndjson', OUT / 'development.ndjson'})}))
    print('admitted', len(train), 'training', len(development), 'development', flush=True)


if __name__ == '__main__': main()
