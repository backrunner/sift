#!/usr/bin/env python3
"""Write the gold review overlay and the evaluation set registry.

Fixes come from reading 212 rows every model got wrong and 100 random rows they all got right, then
sweeping the whole union for each rule found, so a fix never depends on what a model predicted.
Source files stay unchanged. Ambiguous rows stop counting for fine and filing, but a false block
or a missed scam on them still counts.
"""
from collections import Counter
from datetime import datetime, timezone
import json

import evaluate_signal_v100 as e
from filter_policy import identity
import rebuild_v88 as base

ROOT = base.ROOT
UNION = 'build/signal-routing-v91-20261104/union.ndjson'
RULES = dict(
    consumption='Rubric: a transaction notice follows fund direction, so money paid to a merchant is finance.consumption.',
    income='Rubric: an incoming credit is finance.income.',
    carrier='Rubric: a carrier-owned offer is carrier.promotion.',
    broadband='Quality rule: broadband billing belongs to the carrier.',
    credential='Rubric: life.pickup_code requires a pickup credential.',
)
RELABEL = {
    'finance.consumption': ('consumption', (1099, 1131, 1163, 1268, 1269, 1291, 1306, 1321, 1337, 1357, 1377, 1686, 1687, 1745, 1746, 1747)),
    'finance.income': ('income', (801,)),
    'carrier.promotion': ('carrier', (489, 3206, 3207, 3208, 3374, 3375, 3376, 3662, 3663, 3664)),
    'carrier.billing': ('broadband', (800,)),
    'life.express': ('credential', (923,)),
}
AMBIGUOUS = {
    'Person-to-person workplace chat; the service label is not established by the text.': (2679, 2685, 2710, 2903, 2905, 2906, 2926, 2910),
    'Text does not establish the service or fund direction.': (441, 446, 565, 1270, 2789, 2731, 2806, 2494, 3297),
    'Debatable leaf under the rubric, so it should not count for or against a model.': (449, 451, 3452, 3404, 3406, 3596, 3598, 467),
    'Unrendered placeholder text.': (2728,),
}


def overlay_entries(rows):
    entries = []; seen = set()
    for label, (rule, ids) in RELABEL.items():
        for i in ids:
            entries.append(dict(textSHA256=identity(rows[i]['text']), label=label, was=rows[i]['label'], reason=RULES[rule])); seen.add(i)
    for reason, ids in AMBIGUOUS.items():
        expanded = set(ids)
        for i in ids:
            family = rows[i].get('familyId')
            if family: expanded |= {j for j, r in enumerate(rows) if r.get('familyId') == family and r['label'] == rows[i]['label']}
        for i in sorted(expanded - seen):
            entries.append(dict(textSHA256=identity(rows[i]['text']), fine=False, filing=False, reason=reason)); seen.add(i)
    return entries


SETS = {
    'classification': dict(path='tools/apple-trainer/Evaluation/classification-regressions.ndjson', tier='regression', use='Regression floor.', note='182 of 487 rows are wrapped copies of training bodies and always score correct.'),
    'promotion': dict(path='tools/apple-trainer/Evaluation/promotion-regressions.ndjson', tier='regression', use='Regression floor.', note='Almost no links.'),
    'billing-card': dict(path='tools/apple-trainer/Evaluation/billing-card-regressions.ndjson', tier='regression', use='Regression floor.', note='30 rows.'),
    'union': dict(path=UNION, tier='development', use='Free diagnosis and large regressions.', note='Exposed many times, and gates fit it. About 90% of link rows use placeholder hosts.'),
    'link180': dict(path='build/signal-validation-v94-20261104/fresh.ndjson', tier='spent', use='Diagnosis of real-format links.', note='Read by v94.'),
    'contrast96': dict(path='build/signal-contrast-v92-20261104/development.ndjson', tier='spent', use='Diagnosis.', note='Placeholder hosts.'),
    'cjk64': dict(path='build/signal-cjk-v96-20261104/development.ndjson', tier='spent', use='Diagnosis of zh and ja register.', note='Read by the v94 final check.'),
    'real45': dict(path='build/signal-real-v90-20261103/test-real-visible.ndjson', tier='spent-real', use='Direction on real rows.', note='Small and mostly English.'),
    'real79': dict(path='build/signal-real-v95-20261104/test-real.ndjson', tier='spent-real', use='Direction on real rows.', note='English and dated.'),
    'official5': dict(path='build/signal-real-v90-20261103/test-official.ndjson', tier='spent-real', use='Named false-block cases.', note='5 templates.'),
    'realistic287': dict(path='build/signal-realistic-v101-20261104/test.ndjson', tier='sealed', use='Primary test: harm, false blocks and filing in received-SMS style.', note='Written before the v101 arms trained, one independent scenario per row. Synthetic.'),
    'dev67': dict(path='build/signal-realistic-v101-20261104/development.ndjson', tier='development', use='Epoch selection in the same style.', note='Never trained.'),
    'reserved624': dict(path='build/signal-reserved-review-v99-20261104/reserved-reviewed.ndjson', tier='sealed', use='One comparison of rebuilt candidates on fine labels.', note='Not for harm, links, real-world estimates or claims against SAM.'),
}


def main():
    rows = base.read(ROOT / UNION); entries = overlay_entries(rows)
    e.OVERLAY.write_text(json.dumps(dict(createdUTC=datetime.now(timezone.utc).isoformat(), reviewer='assistant, no independent native review', reviewed=dict(modelConsensusErrors=212, controlAllCorrect=100, controlGoldProblems=dict(wrong=1, vague=3)),
        rule='Applied to every model alike. Report raw and reviewed views. Rule-based fixes were swept across the union, not only rows models got wrong.',
        unmeasured='The control implies about 1% to 4% of rows models agree on may also have wrong or vague gold; those rows stay as they are.',
        entries=entries), ensure_ascii=False, indent=1) + '\n')
    sets = {}
    for name, spec in SETS.items():
        sets[name] = dict(spec, rows=len(base.read(ROOT / spec['path'])), sha256=base.sha(ROOT / spec['path']))
    e.REGISTRY.write_text(json.dumps(dict(createdUTC=datetime.now(timezone.utc).isoformat(), primary='Serious errors: harmful missed, normal to junk, normal to promotion. Then overall errors, then fine labels.', tiers=dict(regression='Must not regress.', development='May be read and reused; never proves a gain.', spent='Seen by earlier studies; direction only.', sealed='Scored once by rule.'), sets=sets), ensure_ascii=False, indent=1) + '\n')
    print(Counter('relabel' if 'label' in x else 'ambiguous' for x in entries))


if __name__ == '__main__':
    main()
