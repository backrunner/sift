#!/usr/bin/env python3
"""Local qualification of the v101 routed candidate; same checks as v97, no device claim.

parity runs SignalLocalProbe on every saved gate-36 decision set. finalize writes validation metrics
from Core ML decisions and qualification.json for the publishing gate.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess

import evaluate_signal_v100 as evaluation
import rebuild_v88 as base
import rebuild_v101 as study
import routing_refit_v91 as v91

ROOT = base.ROOT
OUT = ROOT / 'build/signal-qualify-v101-20261104'
ARM = 'process-data-v101'
FINAL = study.OUT / 'final-check'


def reference(name, seed):
    if name in ('reserved624', 'real79'): return base.read(FINAL / f'{ARM}-{seed}-{name}-swift.ndjson')
    return base.read(study.OUT / f'{ARM}-gate36-{seed}-{name}-swift.ndjson')


def sets():
    return {'realistic287': base.read(ROOT / study.DATA / 'test.ndjson'), **v91.fixed_suites(), **v91.spent_sets(), 'reserved624': evaluation.load_set('reserved624'), 'real79': evaluation.load_set('real79')}


def parity(args):
    OUT.mkdir(exist_ok=True); a = evaluation.actions(); fixed = set(v91.fixed_suites()); result = {}
    for name, rows in sets().items():
        source = args.work / f'v101-rows-{name}.ndjson'; report = args.work / f'v101-rep-{name}.json'; out = OUT / f'coreml-{name}.ndjson'
        source.write_text(''.join(json.dumps(dict(text=r['text'], label=r['label']), ensure_ascii=False) + '\n' for r in rows))
        subprocess.run([str(args.probe), str(args.staged), str(source), str(report), str(out)], check=True)
        made = base.read(out); expected = reference(name, args.seed)
        same_action = sum(d['engineAction'] == p['engineAction'] for d, p in zip(made, expected, strict=True))
        same_label = sum(d['engineLabel'] == p['engineLabel'] for d, p in zip(made, expected, strict=True))
        result[name] = dict(rows=len(rows), failures=json.loads(report.read_text())['failures'], actionAgreement=same_action, labelAgreement=same_label,
                            score=v91.fixed_summary(rows, made, a) if name in fixed else evaluation.report(rows, made, a))
        print(name, len(rows), same_action, same_label, flush=True)
    (OUT / 'coreml-parity.json').write_text(json.dumps(result, indent=1, ensure_ascii=False) + '\n')


def finalize(args):
    result = json.loads((OUT / 'coreml-parity.json').read_text()); a = evaluation.actions(); rows = base.read(ROOT / study.DATA / 'test.ndjson'); made = base.read(OUT / 'coreml-realistic287.ndjson')
    scored = Counter(); correct = Counter()
    for row, decision in zip(rows, made, strict=True):
        scored[row['language']] += 1; correct[row['language']] += evaluation.error_of(row, decision, a) is None
    path = args.candidate / 'SiftSignalModel.manifest.json'; manifest = json.loads(path.read_text()); fixed, promotion = result['classification'], result['promotion']; compared = sum(v['rows'] for v in result.values())
    # Policy action: commercial messages sent to junk count as correct, per the approved v47 policy. Strict stays below.
    manifest['validationMetrics'] = dict(fixedAccuracy=fixed['score']['tolerantAction'] / fixed['rows'], promotionAccuracy=promotion['score']['tolerantAction'] / promotion['rows'],
        fp16Agreement=sum(v['actionAgreement'] for v in result.values()) / compared, languageAccuracy={k: correct[k] / scored[k] for k in sorted(scored)})
    path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    run = lambda kind, mode, i: json.loads((args.work / f'v101-r-{kind}-{mode}-{i}.json').read_text()); long = lambda kind, mode: json.loads((args.work / f'v101-long-{kind}-{mode}.json').read_text())
    memory = {k: {m: dict(peaks1280=[run(k, m, i)['peakFootprint'] for i in (1, 2, 3)], peak10240=long(k, m)['peakFootprint'], final10240=long(k, m)['finalFootprint'], failures=long(k, m)['failures'], p50Milliseconds=long(k, m)['p50Milliseconds'], p95Milliseconds=long(k, m)['p95Milliseconds']) for m in ('normal', 'restricted')} for k in ('ctrl', 'cand')}
    differences = sum(v['rows'] * 2 - v['actionAgreement'] - v['labelAgreement'] for v in result.values())
    verdict = json.loads((study.OUT / 'verdict.json').read_text())
    (OUT / 'qualification.json').write_text(json.dumps(dict(schemaVersion=1, artifactSHA256=manifest['sha256'], version=manifest['version'], track=manifest['releaseTrack'],
        localQualified=differences == 0 and not any(v['failures'] for v in result.values()), deviceQualified=False, decisionDifferences=differences, rowsCompared=compared,
        sealedComparison='signal-rebuild-v101', sealedComparisonPassed=verdict['passed'][ARM] is True,
        strictAction=dict(classification=fixed['score']['strictAction'], promotion=promotion['score']['strictAction'], rows=dict(classification=fixed['rows'], promotion=promotion['rows'])),
        memory=memory, downloadBytes=manifest['downloadBytes'], environment='Mac, CPU only; the restricted profile denies IOSurface only.',
        limits=['Not the iPhone allocator, the IdentityLookup sandbox or an enforced budget.', 'Real extension peak, cold launch and live SMS filtering remain untested.', f'Seed {args.seed} was fixed by rule.', 'Sealed test and added training rows share one author.']), indent=1) + '\n')
    print(manifest['validationMetrics'], 'differences', differences, 'rows', compared)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('stage', choices=('parity', 'finalize')); parser.add_argument('--seed', type=int, default=321)
    parser.add_argument('--candidate', type=Path, default=OUT / 'candidate-321'); parser.add_argument('--probe', type=Path, default=Path('/tmp/sift-qual/probe'))
    parser.add_argument('--staged', type=Path, default=Path('/tmp/sift-qual/cand101')); parser.add_argument('--work', type=Path, default=Path('/tmp/sift-qual'))
    parsed = parser.parse_args(); globals()[parsed.stage](parsed)
