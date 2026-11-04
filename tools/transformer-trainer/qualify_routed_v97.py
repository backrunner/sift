#!/usr/bin/env python3
"""Local qualification of an exported routed candidate. No device claim, no publishing.

Stages: parity runs SignalLocalProbe on every saved evaluation set and compares each engine
decision with the PyTorch-based replay. finalize records validation metrics in the manifest
from the Core ML decisions, and writes qualification.json for the dev publishing gate.
Stage the candidate on internal disk first, since mapped files behave differently on an
external volume: --probe and --staged point there.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess

import rebuild_v88 as base
import rebuild_v94 as v94
import routing_refit_v91 as v91
from evaluation_audit_v86 import action_map

ROOT = base.ROOT
OUT = ROOT / 'build/signal-qualify-v97-20261104'
V94 = ROOT / 'build/signal-rebuild-v94-20261104'
FINAL = ROOT / 'build/signal-final-check-v94-20261104'
EXTRA = dict(dev64='build/signal-cjk-v96-20261104/development.ndjson', real79='build/signal-real-v95-20261104/test-real.ndjson')
EXTRA_NAME = dict(dev64='development', real79='real')


def actions(): return action_map(json.loads((ROOT / 'packages/taxonomy/taxonomy.json').read_text()))


def reference(name, seed):
    if name in EXTRA: return base.read(FINAL / f'free-v92-{seed}-{EXTRA_NAME[name]}-swift.ndjson')
    return base.read(V94 / f'free-v92-{seed}-gate36-{name}-swift.ndjson')


def parity(args):
    known = dict(fresh=base.read(ROOT / v94.FRESH), union=base.read(v91.OUT / 'union.ndjson'), **v91.fixed_suites(), **v91.spent_sets())
    sets = {**known, **{n: base.read(ROOT / p) for n, p in EXTRA.items()}}; fixed = set(v91.fixed_suites()); result = {}; a = actions()
    for name, rows in sets.items():
        source = args.work / f'rows-{name}.ndjson'; report = args.work / f'rep-{name}.json'; out = OUT / f'coreml-{name}.ndjson'
        source.write_text(''.join(json.dumps(dict(text=r['text'], label=r['label']), ensure_ascii=False) + '\n' for r in rows))
        subprocess.run([str(args.probe), str(args.staged), str(source), str(report), str(out)], check=True)
        decisions = base.read(out); expected = reference(name, args.seed)
        same_action = sum(d['engineAction'] == p['engineAction'] for d, p in zip(decisions, expected, strict=True))
        same_label = sum(d['engineLabel'] == p['engineLabel'] for d, p in zip(decisions, expected, strict=True))
        metric = v94.measured(rows, decisions, a, name, fixed); metric.pop('perRowCorrect', None)
        result[name] = dict(rows=len(rows), failures=json.loads(report.read_text())['failures'], actionAgreement=same_action, labelAgreement=same_label, score=metric)
        print(name, len(rows), same_action, same_label, flush=True)
    (OUT / 'coreml-parity.json').write_text(json.dumps(result, indent=1, ensure_ascii=False) + '\n')


def sealed_comparison_passed():
    settings = json.loads((V94 / 'verdict.json').read_text())['settings']
    return settings['free-v92/gate36']['qualifies'] is True


def finalize(args):
    parity_result = json.loads((OUT / 'coreml-parity.json').read_text()); a = actions()
    rows = base.read(ROOT / v94.FRESH); decisions = base.read(OUT / 'coreml-fresh.ndjson')
    scored = Counter(); correct = Counter()
    for row, decision in zip(rows, decisions, strict=True):
        scored[row['language']] += 1; correct[row['language']] += v94.error_type(row, decision, a) is None
    path = args.candidate / 'SiftSignalModel.manifest.json'; manifest = json.loads(path.read_text())
    fixed, promotion = parity_result['classification'], parity_result['promotion']
    rows_compared = sum(v['rows'] for v in parity_result.values())
    # Policy action: commercial messages sent to junk count as correct, per the approved v47 policy.
    # Strict scores stay in qualification.json, because promotion is lower there.
    manifest['validationMetrics'] = dict(fixedAccuracy=fixed['score']['tolerantAction'] / fixed['rows'], promotionAccuracy=promotion['score']['tolerantAction'] / promotion['rows'],
        fp16Agreement=sum(v['actionAgreement'] for v in parity_result.values()) / rows_compared, languageAccuracy={k: correct[k] / scored[k] for k in sorted(scored)})
    path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    def run(a_, m, i): return json.loads((args.work / f'r-{a_}-{m}-{i}.json').read_text())
    def long(a_, m): return json.loads((args.work / f'long-{a_}-{m}.json').read_text())
    memory = {a_: {m: dict(peaks1280=[run(a_, m, i)['peakFootprint'] for i in (1, 2, 3)], peak10240=long(a_, m)['peakFootprint'], final10240=long(a_, m)['finalFootprint'],
                           failures=long(a_, m)['failures'], p50Milliseconds=long(a_, m)['p50Milliseconds'], p95Milliseconds=long(a_, m)['p95Milliseconds'])
                   for m in ('normal', 'restricted')} for a_ in ('ctrl', 'cand')}
    differences = sum(v['rows'] * 2 - v['actionAgreement'] - v['labelAgreement'] for v in parity_result.values())
    (OUT / 'qualification.json').write_text(json.dumps(dict(schemaVersion=1, artifactSHA256=manifest['sha256'], version=manifest['version'], track=manifest['releaseTrack'],
        localQualified=differences == 0 and not any(v['failures'] for v in parity_result.values()), deviceQualified=False,
        sealedComparison='signal-rebuild-v94', sealedComparisonPassed=sealed_comparison_passed(), decisionDifferences=differences, rowsCompared=rows_compared,
        strictAction=dict(classification=fixed['score']['strictAction'], promotion=promotion['score']['strictAction'], rows=dict(classification=fixed['rows'], promotion=promotion['rows'])),
        memory=memory, downloadBytes=manifest['downloadBytes'], environment='Mac, CPU only; the restricted profile denies IOSurface only.',
        limits=['Not the iPhone allocator, the IdentityLookup sandbox or an enforced budget.', 'Real extension peak, cold launch and live SMS filtering remain untested.', f'Seed {args.seed} was fixed by rule, not chosen from results.']), indent=1) + '\n')
    print(manifest['validationMetrics'], 'differences', differences, 'rows', rows_compared)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('parity', 'finalize')); parser.add_argument('--seed', type=int, default=321)
    parser.add_argument('--candidate', type=Path, default=OUT / 'candidate-321'); parser.add_argument('--probe', type=Path, default=Path('/tmp/sift-qual/probe'))
    parser.add_argument('--staged', type=Path, default=Path('/tmp/sift-qual/cand')); parser.add_argument('--work', type=Path, default=Path('/tmp/sift-qual'))
    parsed = parser.parse_args(); globals()[parsed.stage](parsed)
