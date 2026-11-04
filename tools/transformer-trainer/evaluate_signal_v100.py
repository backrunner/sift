#!/usr/bin/env python3
"""One scorer for every Signal comparison, so no study can choose a flattering view.

Serious errors come first. Filing and fine labels follow, split by language, link and origin.
Intervals resample message families, since translations and templates are not independent.
Gold fixes are an explicit overlay that applies to every model alike, and both raw and reviewed
views are reported. Sealed sets are refused unless their single use is recorded.
"""
import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import random
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = ROOT / 'tools/transformer-trainer/experiments/signal-evaluation-v100-registry.json'
OVERLAY = ROOT / 'tools/transformer-trainer/experiments/signal-gold-review-v100.json'
SERIOUS = ('harmful missed', 'normal to junk', 'normal to promotion')
ORDER = SERIOUS + ('commercial missed', 'filing')
RESAMPLES = 2000


def read(path): return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def kind_of(row):
    review = row.get('filterReview')
    if review: return review['kind']
    if row['label'] == 'spam': return 'harmful'
    return 'commercial' if row['label'] in ('promotion', 'carrier.promotion') else 'normal'


def scored(row):
    review = row.get('filterReview')
    return not review or (review['kind'] != 'unresolved' and review['inputForm'] != 'scenario-description')


def error_of(row, decision, actions, filing=True):
    """The one error definition: harm first, then false blocks, then commercial, then filing."""
    kind = kind_of(row); action = decision['engineAction']
    if kind == 'harmful': return None if action == 'junk' else 'harmful missed'
    if kind == 'commercial': return None if action in ('promotion', 'junk') else 'commercial missed'
    if action == 'junk': return 'normal to junk'
    if action == 'promotion': return 'normal to promotion'
    return 'filing' if filing and action != actions[row['label']] else None


def link_kind(text):
    hosts = re.findall(r'https?://([^/\s]+)', text)
    if not hosts: return 'no link'
    return 'placeholder host' if any(h.endswith('.invalid') for h in hosts) else 'real-format host'


def origin_of(row):
    source = str(row.get('source', '')).split(':')[0]
    if source.startswith(('real-', 'official-', 'public-', 'cloudkit')): return 'real or public'
    if source.startswith(('authored', 'augmentation', 'acceptance', 'synthetic')): return 'authored'
    return 'other'


def families(rows):
    """Explicit family first, then shared signature, so translations and templates count once."""
    from import_reviewed_public import keys
    parent = list(range(len(rows))); owner = {}
    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]; i = parent[i]
        return i
    for i, row in enumerate(rows):
        marks = set(keys(row['text'], family=True))
        if row.get('familyId'): marks.add('family:' + str(row['familyId']))
        for mark in marks: parent[find(i)] = find(owner.setdefault(mark, i))
    return [find(i) for i in range(len(rows))]


def apply_overlay(rows, overlay):
    from filter_policy import identity
    changes = {e['textSHA256']: e for e in overlay['entries']}; result = []
    for row in rows:
        entry = changes.get(identity(row['text']))
        if not entry: result.append(dict(row, _fine=True, _filing=True)); continue
        result.append(dict(row, label=entry.get('label', row['label']), _fine=entry.get('fine', True), _filing=entry.get('filing', True)))
    return result


def wilson(hit, total, z=1.96):
    if not total: return (None, None)
    p = hit / total; d = 1 + z * z / total; c = p + z * z / (2 * total)
    m = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total))
    return (round((c - m) / d, 4), round((c + m) / d, 4))


def report(rows, decisions, actions):
    pairs = [(r, d) for r, d in zip(rows, decisions, strict=True) if scored(r)]
    errors = Counter(); strata = defaultdict(Counter); kinds = Counter()
    for row, decision in pairs:
        kind = kind_of(row); kinds[kind] += 1
        error = error_of(row, decision, actions, row.get('_filing', True))
        if error: errors[error] += 1
        fine_ok = decision['engineLabel'] == row['label']; use_fine = row.get('_fine', True) and row.get('filterReview', {}).get('fineLabelScored', True)
        for axis, value in (('language', row.get('language', 'unknown')), ('link', link_kind(row['text'])), ('origin', origin_of(row)), ('kind', kind)):
            cell = strata[f'{axis}: {value}']
            cell['rows'] += 1; cell['serious'] += error in SERIOUS; cell['errors'] += error is not None
            cell['fineScored'] += use_fine; cell['fineCorrect'] += use_fine and fine_ok
    fine_scored = sum(c['fineScored'] for k, c in strata.items() if k.startswith('kind:'))
    fine_correct = sum(c['fineCorrect'] for k, c in strata.items() if k.startswith('kind:'))
    serious = sum(errors[k] for k in SERIOUS); total = len(pairs)
    harm = kinds['harmful']; normal = kinds['normal']
    return dict(rows=total, serious=serious, errors={k: errors[k] for k in ORDER}, kinds=dict(kinds),
        harmfulRecall=dict(rate=round(1 - errors['harmful missed'] / harm, 4), interval=wilson(harm - errors['harmful missed'], harm)) if harm else None,
        falseBlockRate=dict(rate=round((errors['normal to junk'] + errors['normal to promotion']) / normal, 4), interval=wilson(errors['normal to junk'] + errors['normal to promotion'], normal)) if normal else None,
        fine=dict(correct=fine_correct, scored=fine_scored, rate=round(fine_correct / fine_scored, 4) if fine_scored else None),
        strata={k: dict(v) for k, v in sorted(strata.items())})


def compare(rows, a, b, actions, seed=100):
    """Paired family bootstrap: positive favours a. Serious, then all errors, then fine."""
    groups = families(rows); cells = defaultdict(lambda: [0, 0, 0]); discordant = Counter()
    for row, x, y, group in zip(rows, a, b, groups, strict=True):
        if not scored(row): continue
        ex, ey = error_of(row, x, actions, row.get('_filing', True)), error_of(row, y, actions, row.get('_filing', True))
        sx, sy = ex in SERIOUS, ey in SERIOUS
        cells[group][0] += int(sy) - int(sx); cells[group][1] += int(ey is not None) - int(ex is not None)
        if row.get('_fine', True) and row.get('filterReview', {}).get('fineLabelScored', True):
            cells[group][2] += int(x['engineLabel'] == row['label']) - int(y['engineLabel'] == row['label'])
        discordant['a only right, serious'] += sy and not sx; discordant['b only right, serious'] += sx and not sy
    values = list(cells.values()); rng = random.Random(seed); out = dict(families=len(values), discordant=dict(discordant))
    for index, name in enumerate(('seriousFewerInA', 'errorsFewerInA', 'fineMoreInA')):
        draws = sorted(sum(rng.choices(column, k=len(column))) for column in [[v[index] for v in values]] for _ in range(RESAMPLES))
        out[name] = dict(difference=sum(v[index] for v in values), low=draws[int(.025 * RESAMPLES)], high=draws[int(.975 * RESAMPLES)])
    return out


def actions():
    from evaluation_audit_v86 import action_map
    return action_map(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))


def load_set(name, reviewed=True):
    registry = json.loads(REGISTRY.read_text()); spec = registry['sets'][name]
    if spec['tier'] == 'sealed' and not spec.get('opened'):
        raise SystemExit(f'{name} is sealed; record its single use in the registry first')
    rows = read(ROOT / spec['path'])
    return apply_overlay(rows, json.loads(OVERLAY.read_text())) if reviewed else apply_overlay(rows, dict(entries=[]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('set'); parser.add_argument('decisions', nargs='+', type=Path)
    parser.add_argument('--raw', action='store_true', help='score original gold instead of the reviewed overlay')
    args = parser.parse_args(); rows = load_set(args.set, not args.raw); a = actions()
    runs = [read(p) for p in args.decisions]
    print(json.dumps(dict(reports=[report(rows, d, a) for d in runs], comparison=compare(rows, runs[0], runs[1], a) if len(runs) == 2 else None), ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
