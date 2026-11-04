"""Build the official-template test set from sources with explicit reuse terms.

These are templates published by senders, not received messages. They stay test-only,
apart from any model training, and are reported apart from real-source rows.
"""
import hashlib
import json

import build_real_v90 as real
from import_reviewed_public import keys
from retired_samples import RetiredSamples

ROOT = real.ROOT
TRAINING = real.TRAINING
LEDGER = TRAINING / 'signal-official-v90-review.json'
V33 = TRAINING / 'public-sms-v33-review.json'
OUTPUT = real.OUT / 'test-official.ndjson'


def from_v33(record):
    return dict(text=record['text'], label=record['label'], language=record['language'], source='official-v33:' + record['id'], familyId=record['family'])


def to_evaluation(row):
    return dict(row, filterReview=dict(kind='normal', inputForm='sms-text', fineLabelScored=True, basis='Official template with explicit reuse terms; assistant review.'))


def main():
    ledger = json.loads(LEDGER.read_text()); rows = [from_v33(r) for r in json.loads(V33.read_text())['records'] if not r.get('excluded')]
    rows += [dict(text=r['text'], label=r['label'], language=r['language'], source='official-v90:' + r['id'], familyId=r['family']) for r in ledger['templates']]
    protected = set(); paths = [real.OUT / 'training.ndjson', real.OUT / 'test-real-visible.ndjson', real.OUT / 'test-real-reported.ndjson', ROOT / 'build/signal-fine-v81-20261102/development.ndjson', ROOT / 'build/signal-fine-v81-20261102/reserved.ndjson',
             ROOT / 'build/signal-corpus-review-20261027/all-eval-reviewed.ndjson', *sorted((ROOT / 'tools/transformer-trainer/Evaluation').glob('*.ndjson')), *sorted((ROOT / 'tools/apple-trainer/Evaluation').glob('*.ndjson'))]
    for path in paths:
        for row in real.read(path): protected |= set(keys(row['text'], family=True))
    retired = RetiredSamples(); kept = []
    for row in rows:
        if retired.reason(row): raise ValueError('retired template: ' + row['source'])
        if keys(row['text'], family=True) & protected: raise ValueError('template overlaps existing data: ' + row['source'])
        kept.append(to_evaluation(row))
    OUTPUT.write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in kept))
    print(json.dumps(dict(rows=len(kept), languages={g: sum(r['language'] == g for r in kept) for g in ('ja', 'en', 'zh')}, labels=[r['label'] for r in kept], sha256=hashlib.sha256(OUTPUT.read_bytes()).hexdigest()[:16]), ensure_ascii=False))


if __name__ == '__main__': main()
