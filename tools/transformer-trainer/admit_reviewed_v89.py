"""Build the v89 candidate pool: the v85 reviewed pool plus ledger-admitted rows.

Bodies come only from current Training/ packages, selected by hash from the
signed-off ledger. Retirement, quality, label and family-isolation rules are
reasserted here. This produces a training candidate; it does not train or install.
"""
import argparse
from collections import Counter
import glob
import hashlib
import json
from pathlib import Path

from import_reviewed_public import keys
from model_contract import model_labels
from prepare_approved_signal import quality_reason
from retired_samples import RetiredSamples

ROOT = Path(__file__).resolve().parents[2]
TRAINING = ROOT / 'tools/apple-trainer/Training'
LEDGER = TRAINING / 'signal-admission-v89-review.json'
BASE = ROOT / 'build/signal-fine-v85-20261103/training-quality-next.ndjson'
OUT = ROOT / 'build/signal-admission-v89-20261103'
ISOLATION = ['build/signal-fine-v81-20261102/development.ndjson', 'build/signal-fine-v81-20261102/reserved.ndjson',
             'build/signal-corpus-review-20261027/all-eval-reviewed.ndjson']
SOURCE_PREFIX = 'reviewed-admission-v89:'
CORE = ('zh', 'en', 'ja')


def read(path):
    return [json.loads(line) for line in Path(path).read_text(errors='ignore').splitlines() if line.strip()]


def digest(text): return hashlib.sha256(text.encode()).hexdigest()


def admitted_hashes(ledger):
    if ledger['independentNativeReview'] or ledger['relabeled']:
        raise ValueError('ledger must not claim native review or relabel rows')
    for row in ledger['decisions']:
        if row['decision'] not in ('admit', 'exclude') or not row['reason']:
            raise ValueError('every decision needs an outcome and a reason')
    return {row['textSHA256']: row for row in ledger['decisions'] if row['decision'] == 'admit'}


def merge(base, candidates, decisions, protected, retired):
    """Reject anything a ledger decision did not admit or a guard would refuse."""
    seen = set().union(*(keys(r['text'], family=True) for r in base)); kept = []
    for row in candidates:
        decision = decisions.get(digest(row['text']))
        if decision is None: continue
        if row['label'] != decision['label']: raise ValueError('label drift for ' + decision['textSHA256'])
        family = keys(row['text'], family=True)
        reason = (retired.reason(row) or quality_reason(row)
                  or ('protected-holdout-family' if family & protected else None)
                  or ('duplicate-family' if family & seen else None))
        if reason: raise ValueError(f"{reason}: {decision['textSHA256']}")
        seen |= family
        kept.append({'text': row['text'], 'label': row['label'], 'language': decision['language'],
                     'source': SOURCE_PREFIX + decision['originalSource']})
    if len(kept) != len(decisions):
        raise ValueError(f'admitted {len(kept)} rows but ledger lists {len(decisions)}')
    return kept


def coverage(rows, labels):
    counts = Counter((r['label'], r['language']) for r in rows)
    return {f'{l}:{g}': counts[(l, g)] for l in labels for g in CORE if counts[(l, g)] < 10}


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.parse_args()
    if OUT.exists(): raise ValueError('output exists; use a new version')
    decisions = admitted_hashes(json.loads(LEDGER.read_text()))
    base = read(BASE); candidates = {}
    for path in sorted(glob.glob(str(TRAINING / '*.ndjson'))):
        for row in read(path):
            if isinstance(row, dict) and digest(row.get('text', '')) in decisions: candidates.setdefault(row['text'], row)
    protected = set()
    evaluation = [ROOT / p for p in ISOLATION] + [Path(p) for p in glob.glob(str(ROOT / 'tools/transformer-trainer/Evaluation/*.ndjson'))
                                                  + glob.glob(str(ROOT / 'tools/apple-trainer/Evaluation/*.ndjson'))]
    for path in evaluation:
        for row in read(path):
            if isinstance(row, dict) and 'text' in row: protected |= set(keys(row['text'], family=True))
    new = merge(base, candidates.values(), decisions, protected, RetiredSamples())
    taxonomy = json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text())
    rows = base + new; labels = sorted(model_labels({l['id'] for g in taxonomy['groups'] for l in g['leaves']}))
    gaps = coverage(rows, labels)
    if gaps: raise ValueError(f'core coverage below ten rows: {gaps}')
    OUT.mkdir(parents=True)
    (OUT / 'training.ndjson').write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in rows))
    report = dict(base=str(BASE.relative_to(ROOT)), baseRows=len(base), admittedRows=len(new), totalRows=len(rows),
        admittedByLanguage=Counter(r['language'] for r in new), admittedByLabel=Counter(r['label'] for r in new),
        ledgerSHA256=hashlib.sha256(LEDGER.read_bytes()).hexdigest(), trainingSHA256=hashlib.sha256((OUT / 'training.ndjson').read_bytes()).hexdigest(),
        evaluationFilesChecked=len(evaluation), protectedFamilySignatures=len(protected),
        trained=False, releaseEligible=False, newIndependentFinal=False)
    (OUT / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: report[k] for k in ('baseRows', 'admittedRows', 'totalRows', 'admittedByLanguage', 'evaluationFilesChecked')}))


if __name__ == '__main__': main()
