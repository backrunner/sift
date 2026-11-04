"""Admit the v94 link test before any model sees it, and write host-balanced training."""
from collections import Counter
import json
from pathlib import Path
import re

from approved_signal import ROOT
from author_fresh_v94 import cases
from filter_policy import identity, training_kind
from import_reviewed_public import keys
from prepare_approved_signal import quality_reason
from prepare_enrichment_v16 import suffixes
from prepare_families_v60 import read, sha, write, rows_file
from public_group_isolation import shingles, similar
from retired_samples import RetiredSamples

OUT = ROOT / 'build/signal-validation-v94-20261104'
TRAINING = ROOT / 'build/signal-contrast-v92-20261104/training.ndjson'
LANGUAGES = ('zh', 'en', 'ja')
DOMAINS = dict(zh='cn', en='com', ja='jp')
INVALID = re.compile(r'https://([\w-]+)\.invalid(?=[/\s]|$)')
BASIS = {'spam': 'Visible malicious clause: a fee, card, credential or code request, or transfer demand, not the link alone.',
         'promotion': 'New optional offer; no harmful collection mechanism.'}


def realistic(row):
    """Authored hosts are opaque by design, so a fictional real-format host keeps the gold."""
    return dict(row, text=INVALID.sub(lambda m: f'https://{m[1]}.{DOMAINS[row["language"]]}', row['text']))


def main():
    from transformers import AutoTokenizer
    assert not (OUT / 'admission.json').exists(); OUT.mkdir(exist_ok=True)
    paths = {TRAINING, ROOT / 'build/signal-contrast-v92-20261104/development.ndjson'}
    for folder in ('tools/apple-trainer/Training', 'tools/apple-trainer/Evaluation', 'tools/transformer-trainer/Evaluation', 'build/signal-fine-v81-20261102', 'build/signal-real-v90-20261103'):
        paths.update((ROOT / folder).glob('*.ndjson'))
    texts = sorted({r['text'] for p in paths for r in read(p) if 'text' in r})
    known = {identity(k) for t in texts for k in keys(t, family=True)}
    suffix = suffixes(); suffix.tlds.update(('invalid', 'example', 'test')); features = [shingles(t, suffix) for t in texts]
    tokenizer = AutoTokenizer.from_pretrained(ROOT / 'build/signal-sam-retained-v33-20261029/sam-321/checkpoint', local_files_only=True)
    taxonomy = json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text())
    labels = {l['id'] for g in taxonomy['groups'] for l in g['leaves']}
    retired = RetiredSamples(); rows = []; failures = []
    for family, host, events in cases():
        for label, *bodies in events:
            assert label in labels, label
            for language, body in zip(LANGUAGES, bodies, strict=True):
                text = f'{body} https://{host}.{DOMAINS[language]}/n'
                row = dict(text=text, label=label, language=language, familyId=family, source=f'authored-reviewed-v94:{family}', role='test')
                row['filterReview'] = dict(kind=training_kind(label), inputForm='sms-text', fineLabelScored=True, originalLabelPreserved=True, reviewedTextSHA256=identity(text),
                    basis=BASIS.get(label, 'Service event under the taxonomy rubric; a link or sign-in request alone does not make it harmful.'))
                reasons = [r for r in (quality_reason(row), retired.reason(row)) if r]
                sig = {identity(k) for k in keys(text, family=True)}; feature = shingles(text, suffix)
                if len(tokenizer(text)['input_ids']) > 96: reasons.append('beyond-96-token-input')
                if sig & known: reasons.append('signature-overlap')
                near = [texts[i] for i, f in enumerate(features) if similar(feature, f)]
                if near: reasons.append('trigram-overlap')
                if reasons: failures.append(dict(text=text, reasons=reasons, neighbors=near[:2]))
                rows.append(row); known |= sig; features.append(feature); texts.append(text)
    if failures:
        print(json.dumps(failures, ensure_ascii=False, indent=1)); raise ValueError(f'{len(failures)} rows failed before any inference')
    training = read(TRAINING); balanced = [realistic(r) for r in training]
    assert not any('.invalid' in r['text'] for r in balanced)
    changed = sum(a['text'] != b['text'] for a, b in zip(training, balanced))
    rows_file(OUT / 'fresh.ndjson', rows); rows_file(OUT / 'training-hosts.ndjson', balanced)
    write(OUT / 'admission.json', dict(freshRows=len(rows), byKind=dict(Counter(r['filterReview']['kind'] for r in rows)), hostsChanged=changed, stage='pre-inference',
        scope='Assistant-authored synthetic link test with fictional real-format hosts; no native certification. Hosts in training changed only where they were opaque .invalid values.',
        filesSHA256={str(p.relative_to(ROOT)): sha(p) for p in sorted(paths | {Path(__file__), Path(__file__).with_name('author_fresh_v94.py'), OUT / 'fresh.ndjson', OUT / 'training-hosts.ndjson'})}))
    print('admitted', len(rows), 'fresh; hosts changed', changed, flush=True)


if __name__ == '__main__': main()
