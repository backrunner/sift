"""Build the v95 real-source test set from licensed archives. Test only, never trained.

Gold comes from a read of each body, not from upstream labels, and is fixed before any
model scores these rows. Rows with intact real hosts only: link-stripped reports cannot
test host behaviour. Untrained v90 candidates join, since real rows are now test-only.
"""
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

from filter_policy import training_kind
from import_reviewed_public import keys
from retired_samples import RetiredSamples

ROOT = Path(__file__).resolve().parents[2]
LEDGER = ROOT / 'tools/apple-trainer/Training/signal-real-v95-review.json'
ARCHIVE = ROOT / 'build/public-source-audit-20261027'
V90 = ROOT / 'build/signal-real-v90-20261103'
OUT = ROOT / 'build/signal-real-v95-20261104'
TRAINING = ('build/signal-contrast-v92-20261104/training.ndjson', 'build/signal-validation-v94-20261104/training-hosts.ndjson')
csv.field_size_limit(10 ** 9)
SOURCES = dict(uci='UCI SMS Spam Collection', mendeley='Mishra and Soni 2022, CC BY 4.0', **{'nus-en': 'NUS SMS Corpus, public domain', 'nus-zh': 'NUS SMS Corpus, public domain'})


def digest(text): return hashlib.sha256(text.encode()).hexdigest()


def read(path): return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def archive_bodies():
    bodies = {}
    for name, file, column in (('uci', 'uci.csv', 'message'), ('mendeley', 'mendeley.csv', 'TEXT')):
        with (ARCHIVE / file).open(encoding='utf-8', errors='replace', newline='') as handle:
            for row in csv.DictReader(handle): bodies.setdefault(digest((row[column] or '').strip()), (name, (row[column] or '').strip()))
    for name, file in (('nus-en', 'en.xml'), ('nus-zh', 'zh.xml')):
        for _, element in ET.iterparse(ARCHIVE / file):
            if element.tag == 'text':
                text = (element.text or '').strip(); bodies.setdefault(digest(text), (name, text))
            if element.tag == 'message': element.clear()
    return bodies


def main():
    ledger = json.loads(LEDGER.read_text()); bodies = archive_bodies(); rows = []
    for item in ledger['accepted']:
        source, text = bodies[item['sha256']]
        rows.append(dict(text=text, label=item['label'], language='en', source=f'real-v95:{source}', familyId=item['campaign'], role='test',
                         filterReview=dict(kind=training_kind(item['label']), inputForm='sms-text', fineLabelScored=item.get('fineLabelScored', True), basis=item['basis'],
                                           originalLabelPreserved=False, reviewedTextSHA256=item['sha256'])))
    for row in read(V90 / 'train-additions.ndjson'):
        rows.append(dict(row, source=row['source'], role='test', filterReview={**row.get('filterReview', {}), 'kind': training_kind(row['label']), 'inputForm': 'sms-text', 'fineLabelScored': True}))
    trained = {k for path in TRAINING for r in read(ROOT / path) for k in keys(r['text'], family=True)}
    spent = {k for name in ('test-real-visible', 'test-official', 'test-real-reported') for r in read(V90 / f'{name}.ndjson') for k in keys(r['text'], family=True)}
    retired = RetiredSamples(); seen = set()
    for row in rows:
        signature = keys(row['text'], family=True)
        if signature & trained: raise ValueError('test row overlaps training: ' + row['text'][:40])
        if signature & spent: raise ValueError('test row overlaps a spent set: ' + row['text'][:40])
        if signature & seen: raise ValueError('duplicate test family: ' + row['text'][:40])
        if retired.reason(dict(row, label='spam')): raise ValueError('test row is retired: ' + row['text'][:40])
        seen |= signature
    OUT.mkdir(exist_ok=True); target = OUT / 'test-real.ndjson'
    if target.exists(): raise ValueError('test set exists; use a new version')
    target.write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in rows))
    (OUT / 'manifest.json').write_text(json.dumps(dict(rows=len(rows), sha256=digest(target.read_text()), kinds=dict(Counter(r['filterReview']['kind'] for r in rows)),
        languages=dict(Counter(r['language'] for r in rows)), labels=dict(Counter(r['label'] for r in rows)), sources=SOURCES, scored=False, ledgerSHA256=digest(LEDGER.read_text()),
        limits=ledger['limits']), ensure_ascii=False, indent=1) + '\n')
    print(rows and len(rows), Counter(r['filterReview']['kind'] for r in rows))


if __name__ == '__main__': main()
