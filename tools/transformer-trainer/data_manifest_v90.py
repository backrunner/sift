"""Describe the v90 data: what each evaluation set can prove, families and gold-review queue.

Reads only. It writes hashes and counts, changes no labels, and scores nothing.
"""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re

import build_real_v90 as real

ROOT = real.ROOT
OUT = real.OUT
EVAL = 'tools/transformer-trainer/Evaluation/'
SETS = {
    'real-visible-v90': ('build/signal-real-v90-20261103/test-real-visible.ndjson', 'Primary real-source test', 'Unscored. Real public reports and templates, English-heavy; small; not a source-independent final.'),
    'real-reported-v90': ('build/signal-real-v90-20261103/test-real-reported.ndjson', 'Diagnostic only', 'Unscored. Real Japanese lures with links removed; bodies alone lack decisive evidence, so a miss is not a clear model error.'),
    'official-templates-v90': ('build/signal-real-v90-20261103/test-official.ndjson', 'Separate normal-message test', 'Unscored. Published by senders, not received messages; five rows, too few for a rate.'),
    'history': (EVAL + 'signal-language-quality-v50-regression.ndjson', 'Regression only', 'Exposed. Close to the r33 lineage; report low-similarity rows separately and do not use as a flat veto.'),
    'old493': (EVAL + 'signal-language-quality-v50-development.ndjson', 'Selection', 'Exposed and mostly authored.'),
    'dev636': ('build/signal-fine-v81-20261102/development.ndjson', 'Selection', 'Exposed and authored. No URLs; a constant-transaction classifier scores 92.45% strict action.'),
    'reserved636': ('build/signal-fine-v81-20261102/reserved.ndjson', 'One-shot final for one frozen candidate', 'Unscored and authored. Requires explicit approval.'),
    'classification487': ('tools/apple-trainer/Evaluation/classification-regressions.ndjson', 'Regression and leak-check', 'Exposed fixed suite.'),
    'promotion150': ('tools/apple-trainer/Evaluation/promotion-regressions.ndjson', 'Regression and leak-check', 'Exposed fixed suite; report strict and policy-tolerant action.'),
    'billing30': ('tools/apple-trainer/Evaluation/billing-card-regressions.ndjson', 'Regression and leak-check', 'Exposed fixed suite.')}
STATUS_WORDING = re.compile(r'client|客户端|クライアント|maintenance|维护|メンテナンス|migration|迁移|移行|archive|归档|export|导出|update|更新', re.I)


def provenance(row):
    source = row.get('source') or ''
    if source.startswith('real-v90:'): return 'real-public'
    if source.startswith('official-'): return 'official-template'
    if source.startswith('public-reviewed'): return 'public-reviewed'
    if source.startswith(('authored', 'acceptance', 'synthetic', 'augmentation', 'reviewed-admission')): return 'authored-or-synthetic'
    if source.startswith('cloudkit'): return 'cloudkit'
    return 'unknown' if not source else 'other'


def family_report(rows):
    groups = real.components([r['text'] for r in rows])
    sizes = Counter(groups); by_label = {}
    for row, group in zip(rows, groups): by_label.setdefault(row['label'], set()).add(group)
    return groups, dict(rows=len(rows), families=len(sizes), largestFamily=max(sizes.values()), rowsInFamiliesOverFive=sum(v for v in sizes.values() if v > 5),
        fewestFamiliesPerLabel=sorted(((len(v), k) for k, v in by_label.items()))[:10], method='char n-gram cosine >= .6, digits normalized, URLs removed; lexical only, translations are not joined')


def gold_queue():
    history = real.read(ROOT / SETS['history'][0])
    rows = [dict(textSHA256=real.digest(r['text']), goldLabel=r['label'], proposedLabel='transaction.other', basis='Status wording under transaction.message; TAXONOMY assigns status notices to transaction.other.', applied=False)
            for r in history if r['label'] == 'transaction.message' and STATUS_WORDING.search(r['text'])]
    return dict(goldChanged=False, note='Candidates for versioned blind review, including correct and incorrect predictions. Keyword-screened, so some may stay as they are.', transactionMessageStatus=rows,
                relatedLedger='build/signal-fine-research-v80-20261102/label-review-ledger.json')


def main():
    pool = real.read(OUT / 'training.ndjson'); groups, families = family_report(pool)
    sidecar = {real.digest(r['text']): int(g) for r, g in zip(pool, groups)}
    (OUT / 'training-families.json').write_text(json.dumps(dict(containsMessageBodies=False, method=families['method'], families=sidecar)) + '\n')
    sets = {}
    for name, (path, role, limit) in SETS.items():
        rows = real.read(ROOT / path)
        sets[name] = dict(path=path, role=role, limit=limit, rows=len(rows), sha256=hashlib.sha256((ROOT / path).read_bytes()).hexdigest(),
            languages=Counter(r.get('language') or 'unrecorded' for r in rows), provenance=Counter(provenance(r) for r in rows))
    train = Counter(provenance(r) for r in pool)
    queue = gold_queue(); (OUT / 'gold-review-queue.json').write_text(json.dumps(queue, ensure_ascii=False, indent=1) + '\n')
    (OUT / 'data-manifest.json').write_text(json.dumps(dict(training=dict(rows=len(pool), provenance=train, languages=Counter(r['language'] for r in pool), familyReport=families),
        evaluationSets=sets, goldReviewCandidates=len(queue['transactionMessageStatus']), openGaps=['Real normal Japanese and Chinese business SMS', 'A source-independent final', 'Independent native-speaker review'],
        qualification='Descriptive. No set here estimates production accuracy.'), ensure_ascii=False, indent=1) + '\n')
    print(json.dumps(dict(training=train, families={k: families[k] for k in ('families', 'largestFamily', 'rowsInFamiliesOverFive')}, fewest=families['fewestFamiliesPerLabel'][:5], gold=len(queue['transactionMessageStatus']), sets={k: v['provenance'] for k, v in sets.items()}), ensure_ascii=False))


if __name__ == '__main__': main()
