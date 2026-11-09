"""Admit v101 rows before any model reads them: test, then development and training."""
from collections import Counter
import json
from pathlib import Path

import author_realistic_test_v101 as test_rows
from approved_signal import ROOT
from filter_policy import identity, training_kind
from import_reviewed_public import keys
from prepare_approved_signal import quality_reason
from prepare_enrichment_v16 import suffixes
from prepare_families_v60 import read, sha, write, rows_file
from public_group_isolation import shingles, similar
from retired_samples import RetiredSamples

OUT = ROOT / 'build/signal-realistic-v101-20261104'
KNOWN = ('tools/apple-trainer/Training', 'tools/apple-trainer/Evaluation', 'tools/transformer-trainer/Evaluation', 'build/signal-fine-v81-20261102', 'build/signal-real-v90-20261103',
         'build/signal-real-v95-20261104', 'build/signal-contrast-v92-20261104', 'build/signal-validation-v94-20261104', 'build/signal-cjk-v96-20261104')
BASIS = {'spam': 'Visible harmful request or explicit illegal offer; a brand or host alone does not decide it.',
         'promotion': 'Optional marketing with no harmful collection.', 'carrier.promotion': 'Carrier-owned optional offer.', '__sift_abstain__': 'Personal conversation with no service event.'}


def known_paths(extra=()):
    paths = set()
    for folder in KNOWN: paths.update((ROOT / folder).glob('*.ndjson'))
    return paths | set(extra)


def staged(entries, role, source, texts):
    """Yield rows with rejection reasons. Every row counts as its own family."""
    suffix = suffixes(); suffix.tlds.update(('invalid', 'example', 'test'))
    known = {identity(k) for t in texts for k in keys(t, family=True)}; features = [shingles(t, suffix) for t in texts]
    taxonomy = json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text())
    labels = {l['id'] for g in taxonomy['groups'] for l in g['leaves']} | {'__sift_abstain__'}; retired = RetiredSamples()
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(ROOT / 'build/signal-sam-retained-v33-20261029/sam-321/checkpoint', local_files_only=True)
    for index, (label, language, text) in enumerate(entries):
        if label not in labels: raise ValueError(label)
        family = f'{source}-{index}'
        row = dict(text=text, label=label, language=language, familyId=family, source=f'authored-reviewed-{source}', role=role,
                   filterReview=dict(kind=training_kind(label), inputForm='sms-text', fineLabelScored=True, originalLabelPreserved=True, reviewedTextSHA256=identity(text),
                                     basis=BASIS.get(label, 'Service event under the taxonomy rubric; a brand, link or sign-in request alone does not make it harmful.')))
        reasons = [r for r in (quality_reason(row), retired.reason(row)) if r]
        signature = {identity(k) for k in keys(text, family=True)}; feature = shingles(text, suffix)
        if len(tokenizer(text)['input_ids']) > 96: reasons.append('beyond-96-token-input')
        if signature & known: reasons.append('signature-overlap')
        near = [texts[i] for i, f in enumerate(features) if similar(feature, f)]
        if near: reasons.append('trigram-overlap')
        known |= signature; features.append(feature); texts.append(text)
        yield row, reasons, near[:1]


def admit(entries, role, source, filename):
    OUT.mkdir(exist_ok=True); target = OUT / filename
    if target.exists(): raise ValueError(f'{filename} exists; use a new version')
    extra = [p for p in OUT.glob('*.ndjson')]
    texts = sorted({r['text'] for p in known_paths(extra) for r in read(p) if 'text' in r}); rows = []; failures = []
    for row, reasons, near in staged(entries, role, source, texts):
        rows.append(row)
        if reasons: failures.append(dict(text=row['text'], reasons=reasons, neighbor=near))
    if failures:
        for f in failures: print(f['reasons'], f['text'][:70], '<<', [n[:70] for n in f['neighbor']])
        raise ValueError(f'{len(failures)} rows failed before any inference')
    rows_file(target, rows)
    print('admitted', role, len(rows), Counter(r['filterReview']['kind'] for r in rows), Counter(r['language'] for r in rows), sha(target)[:16], flush=True)
    return rows


if __name__ == '__main__':
    import author_realistic_train_v101 as training_rows
    if not (OUT / 'test.ndjson').exists(): admit(test_rows.rows(), 'test', 'v101-test', 'test.ndjson')
    if not (OUT / 'development.ndjson').exists(): admit(training_rows.DEVELOPMENT, 'development', 'v101-dev', 'development.ndjson')
    admit(training_rows.TRAINING, 'training', 'v101-train', 'new-training.ndjson')
