"""Record the pre-scoring review of reserved 636 and fix how it may be scored.

Runs before any model scores these rows. The source file stays unchanged. Families whose
fine label is debatable under the rubric keep their action scoring and leave fine scoring.
"""
from collections import Counter
import json
from pathlib import Path
import random

import rebuild_v88 as base

ROOT = base.ROOT
SOURCE = ROOT / 'build/signal-fine-v81-20261102/reserved.ndjson'
OUT = ROOT / 'build/signal-reserved-review-v99-20261104'
FINE_EXCLUDED = {
    'carrier.data_reminder-5': 'A monthly usage report may be a historical report, which the rubric files under carrier.other, not a current usage reminder.',
    'carrier.billing-5': 'Registering paper bill delivery could be a service procedure rather than a billing condition.',
    'travel.other-7': 'A border-document photo check could be read as a personal government case.',
    'finance.credit_card-6': 'Returning a card overpayment sits between card-account management and a refund.',
}
ROWS = 636
FAMILIES = 212
RESAMPLES = 10000


def reviewed(rows):
    """Copy rows, turning off fine scoring only for the listed families."""
    return [{**r, 'filterReview': {**r['filterReview'], 'fineLabelScored': r['familyId'] not in FINE_EXCLUDED}} for r in rows]


def family_difference(a, b, families, seed=98):
    """Paired difference with a 95% interval, resampling families, since translations are correlated."""
    groups = {}
    for x, y, family in zip(a, b, families, strict=True): groups[family] = groups.get(family, 0) + int(x) - int(y)
    values = list(groups.values()); rng = random.Random(seed)
    totals = sorted(sum(rng.choices(values, k=len(values))) for _ in range(RESAMPLES))
    return dict(difference=sum(values), low=totals[int(.025 * RESAMPLES)], high=totals[int(.975 * RESAMPLES)])


def main():
    if OUT.exists(): raise ValueError('review already recorded; use a new version')
    rows = base.read(SOURCE)
    if len(rows) != ROWS or len({r['familyId'] for r in rows}) != FAMILIES: raise ValueError('unexpected reserved rows')
    if not set(FINE_EXCLUDED) <= {r['familyId'] for r in rows}: raise ValueError('unknown family')
    output = reviewed(rows); OUT.mkdir(parents=True)
    base.dump(OUT / 'reserved-reviewed.ndjson', output)
    (OUT / 'review.json').write_text(json.dumps(dict(sourceSHA256=base.sha(SOURCE), reviewedSHA256=base.sha(OUT / 'reserved-reviewed.ndjson'), modelScored=False, rowsRead=ROWS, labelsChanged=0,
        fineExcludedFamilies=FINE_EXCLUDED, fineScoredRows=sum(r['filterReview']['fineLabelScored'] for r in output), kinds=dict(Counter(r['filterReview']['kind'] for r in output)),
        suitableFor='Comparing rebuilt candidates on fine labels and normal filing.',
        notSuitableFor=['Harm decisions: 12 harmful rows in 4 families.', 'Link behaviour: no links.', 'Real-world accuracy: assistant-authored, polished, with no sender style.', 'A fair claim against SAM: rebuilt training pools contain the same author and style.'],
        scoringRule='Single use, after one candidate and its comparator are frozen. Report paired fine and strict action differences per seed, with 95% intervals resampling the 212 families. A candidate improves only if both seeds gain and neither interval falls below zero. Serious errors are reported, not used for harm decisions.',
        limits=['One assistant read the rows; no independent native review.', 'The reader also wrote these rows and may write later test rows, so later rows are overlap-checked against this set.']), ensure_ascii=False, indent=1) + '\n')
    print('recorded', sum(r['filterReview']['fineLabelScored'] for r in output), 'fine rows of', len(output))


if __name__ == '__main__':
    main()
