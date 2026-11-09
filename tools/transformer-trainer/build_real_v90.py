"""Build v90 real-source training rows, a real-source test set and a data manifest.

Bodies come from pinned raw archives, selected by hash from the review ledger.
Upstream labels are never inherited. Campaign components are assigned to one role
before any model scores them. This writes data only: it does not train or install.
"""
import csv
import glob
import hashlib
import html
import json
from collections import Counter
from pathlib import Path
import ast
import re

from import_reviewed_public import keys
from prepare_approved_signal import quality_reason
from retired_samples import RetiredSamples

ROOT = Path(__file__).resolve().parents[2]
TRAINING = ROOT / 'tools/apple-trainer/Training'
LEDGER = TRAINING / 'signal-real-v90-review.json'
RAW = {'imc25': (ROOT / 'build/public-source-audit-20261027/imc25.csv', 'text'),
       'smishx': (ROOT / 'build/public-source-audit-20261103/smishx/dataset.csv', 'SMS')}
BASE = ROOT / 'build/signal-admission-v89-20261103/training.ndjson'
OUT = ROOT / 'build/signal-real-v90-20261103'
CHECKPOINT = ROOT / 'build/signal-sam-retained-v33-20261029/sam-321/checkpoint'
MAX_TOKENS = 96
csv.field_size_limit(10 ** 9)
SIMILAR = .6
URL = re.compile(r'(https?://)?((?:[a-z0-9-]+\.)+[a-z]{2,})(/[^\s,)]*)?', re.I)
PLACEHOLDER = re.compile(r'<[A-Z_]{3,}>')
PERSONAL = re.compile(r'[\w.+-]+@[\w-]+\.\w+|\d{10,}')


def digest(text): return hashlib.sha256(text.encode()).hexdigest()


def read(path):
    rows = []
    for line in Path(path).read_text(errors='ignore').splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and 'text' in row: rows.append(row)
    return rows


def normalize(text):
    """Repair known damage and keep URL scheme and host, as the v27 contract requires."""
    text = ' '.join(html.unescape(text).replace('Â£', '£').split())
    def host_only(match):
        scheme, host, path = match[1], match[2], match[3]
        if not scheme and not path: return match[0]
        return (scheme or 'https://') + host + ('/' if path else '')
    return URL.sub(host_only, text)


def refusal(text):
    if PLACEHOLDER.search(text): return 'upstream-placeholder'
    if PERSONAL.search(text): return 'personal-identifier'
    return None


def expand(decision, raw):
    return ast.literal_eval(raw) if decision.get('splitList') else [raw]


def components(texts):
    """Connect digit-normalized, URL-free near duplicates so a campaign keeps one role."""
    from scipy.sparse.csgraph import connected_components
    from sklearn.feature_extraction.text import TfidfVectorizer
    cleaned = [re.sub(r'\d', '0', URL.sub(' ', t)) for t in texts]
    matrix = TfidfVectorizer(analyzer='char_wb', ngram_range=(2, 4), sublinear_tf=True).fit_transform(cleaned)
    graph = (matrix @ matrix.T).tocsr(); graph.data = (graph.data >= SIMILAR).astype('int8'); graph.eliminate_zeros()
    return connected_components(graph, directed=False)[1]


def role_of(key, test_only):
    if test_only: return 'test'
    return 'test' if int(digest('v90:' + key)[:2], 16) % 2 == 0 else 'train'


def raw_rows():
    rows = {}
    for source, (path, column) in RAW.items():
        with path.open(errors='ignore') as handle:
            for row in csv.DictReader(handle):
                text = (row[column] or '').strip()
                if text: rows.setdefault((source, digest(text)), text)
    return rows


def main():
    from transformers import AutoTokenizer
    if OUT.exists() and (OUT / 'report.json').exists(): raise ValueError('output exists; use a new version')
    ledger = json.loads(LEDGER.read_text()); raws = raw_rows(); retired = RetiredSamples()
    tokenizer = AutoTokenizer.from_pretrained(CHECKPOINT, local_files_only=True)
    protected = set()
    paths = [ROOT / 'build/signal-fine-v81-20261102/development.ndjson', ROOT / 'build/signal-fine-v81-20261102/reserved.ndjson',
             ROOT / 'build/signal-corpus-review-20261027/all-eval-reviewed.ndjson', BASE,
             *map(Path, glob.glob(str(ROOT / 'tools/transformer-trainer/Evaluation/*.ndjson'))), *map(Path, glob.glob(str(ROOT / 'tools/apple-trainer/Evaluation/*.ndjson')))]
    for path in paths:
        for row in read(path): protected |= set(keys(row['text'], family=True))
    kept, rejected, seen = [], Counter(), set()
    for decision in ledger['decisions']:
        raw = raws.get((decision['source'], decision['rawSHA256']))
        if raw is None: raise ValueError('ledger row missing from raw archive: ' + decision['rawSHA256'])
        for part in expand(decision, raw):
            text = normalize(part); row = dict(text=text, label=decision['label'], language=decision['language'], source='real-v90:' + decision['source'])
            family = keys(text, family=True)
            reason = (refusal(text) or retired.reason(row) or quality_reason(row)
                      or ('over-96-tokens' if len(tokenizer(text)['input_ids']) > MAX_TOKENS else None)
                      or ('protected-family' if family & protected else None) or ('duplicate-family' if family & seen else None))
            if reason: rejected[reason] += 1; continue
            seen |= family
            kept.append(dict(row, tier=decision['tier'], kind=decision['kind'], testOnly=bool(decision.get('testOnly')), fineLabelScored=decision['fineLabelScored']))
    groups = components([r['text'] for r in kept])
    keys_by_group = {}
    for row, group in zip(kept, groups): keys_by_group.setdefault(group, []).append(digest(row['text']))
    for row, group in zip(kept, groups):
        members = [r for r, g in zip(kept, groups) if g == group]
        row['familyId'] = 'real-v90-' + min(keys_by_group[group])[:16]
        row['role'] = role_of(row['familyId'], any(m['testOnly'] for m in members))
    OUT.mkdir(parents=True, exist_ok=True)
    train = [dict(text=r['text'], label=r['label'], language=r['language'], source=r['source'], familyId=r['familyId']) for r in kept if r['role'] == 'train']
    def evaluation(row): return dict(text=row['text'], label=row['label'], language=row['language'], source=row['source'], familyId=row['familyId'],
        filterReview=dict(kind=row['kind'], inputForm='sms-text', fineLabelScored=row['fineLabelScored'], basis='v90 assistant review; independent native review not performed.'))
    write = lambda name, rows: (OUT / name).write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in rows))
    visible = [evaluation(r) for r in kept if r['role'] == 'test' and r['tier'] == 'visible']
    reported = [evaluation(r) for r in kept if r['tier'] == 'reported-link-stripped']
    pool = read(BASE) + train
    write('train-additions.ndjson', train); write('test-real-visible.ndjson', visible); write('test-real-reported.ndjson', reported); write('training.ndjson', pool)
    tally = lambda rows: dict(rows=len(rows), kinds=Counter(r['filterReview']['kind'] if 'filterReview' in r else r['label'] for r in rows), languages=Counter(r['language'] for r in rows), families=len({r['familyId'] for r in rows}))
    report = dict(ledgerSHA256=digest(LEDGER.read_text()), rejected=rejected, train=tally(train), testVisible=tally(visible), testReported=tally(reported),
        poolRows=len(pool), evaluationFilesChecked=len(paths), scored=False, trained=False, releaseEligible=False, independentFinal=False,
        trainingSHA256=hashlib.sha256((OUT / 'training.ndjson').read_bytes()).hexdigest())
    (OUT / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: report[k] for k in ('rejected', 'train', 'testVisible', 'testReported', 'poolRows')}, ensure_ascii=False))


if __name__ == '__main__': main()
