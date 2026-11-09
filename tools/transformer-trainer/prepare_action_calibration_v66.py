"""Review and isolate authored calibration/development before any predictions."""
import json
from pathlib import Path
from collections import Counter

from approved_signal import ROOT, verify
from author_action_calibration_v66 import cases
from action_calibration_v66 import validate_design
from filter_policy import identity, training_kind
from import_reviewed_public import keys
from prepare_approved_signal import quality_reason
from prepare_enrichment_v16 import suffixes
from prepare_families_v60 import read, sha, write
from public_group_isolation import shingles, similar
from retired_samples import RetiredSamples

NAME = 'signal-action-calibration-v66'
OUT = ROOT / 'build/signal-action-calibration-v66-20261101'
EVAL = ROOT / 'tools/transformer-trainer/Evaluation'
BASE = ROOT / 'tools/apple-trainer/Training/signal-language-quality-v52.json'


def main():
    if (OUT / 'admission.json').exists(): raise ValueError('admission already frozen')
    OUT.mkdir(exist_ok=True, parents=True)
    data = cases(); validate_design(data)
    base = verify(BASE)
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(ROOT / 'build/signal-sam-retained-v33-20261029/sam-321/checkpoint', local_files_only=True)
    paths = sorted(set((ROOT / 'tools/apple-trainer/Training').glob('*.ndjson'))
        | set((ROOT / 'tools/apple-trainer/Evaluation').glob('*.ndjson')) | set(EVAL.glob('*.ndjson'))
        | {ROOT / name for name in base['filesSHA256'] if name.endswith('.ndjson')})
    assert not any(p.name.startswith(NAME) for p in paths), 'fresh admission paths required'
    required = ('classification-regressions.ndjson', 'promotion-regressions.ndjson', 'billing-card-regressions.ndjson')
    assert all(any(p.name == n for p in paths) for n in required)
    old_texts = sorted({row['text'] for p in paths for row in read(p)})
    suffix = suffixes(); suffix.tlds.update(('test', 'invalid', 'example'))
    features = [shingles(t, suffix) for t in old_texts]
    seen = {identity(k) for t in old_texts for k in keys(t, family=True)} | set(base['protectedSignatureSHA256'])
    retired = RetiredSamples()
    roles = {'calibration': [], 'development': []}; decisions = []; failures = []
    for role, family, service, variants in data:
        staged_features = []; staged_signatures = set()
        for intent, label, translations in zip(('service', 'ordinary', 'commercial', 'harmful'),
                (service, '__sift_abstain__', 'promotion', 'spam'), variants, strict=True):
            for language, text in zip(('zh', 'en', 'ja'), translations, strict=True):
                row = dict(text=text.strip(), label=label, language=language,
                           source=f'authored-reviewed-v66:{family}:{intent}', familyId=family, role=role)
                tokens = len(tokenizer(row['text'])['input_ids'])
                signatures = {identity(k) for k in keys(text, family=True)}
                feat = shingles(text, suffix)
                reason = quality_reason(row) or retired.reason(row)
                if tokens > 96: reason = 'evidence-exceeds-96-token-window'
                if signatures & (seen | staged_signatures): reason = 'exact-digit-template-signature-overlap'
                if any(similar(feat, other) for other in features): reason = 'near-historical-or-other-family'
                if reason: failures.append(dict(family=family, role=role, intent=intent, language=language,
                                               reason=reason, tokens=tokens, text=text))
                basis = {
                    'service': 'Existing paid membership, confirmed order or completed incoming payment; specific status, no optional new purchase.',
                    'ordinary': 'Personal conversation or general information, no provider-specific service event, solicitation or harmful request.',
                    'commercial': 'Optional new paid product, service or membership; explicit purchase invitation without a harmful mechanism.',
                    'harmful': 'Explicit credential/remote control disclosure, gift-card collection, private advance-fee or safe-account coercion, concealed mule transfers, or recruitment-only pyramid.'}[intent]
                row['filterReview'] = dict(kind=training_kind(label), inputForm='sms-text', basis=basis,
                    originalLabelPreserved=True, reviewedTextSHA256=identity(text), fineLabelScored=True)
                roles[role].append(row)
                decisions.append(dict(textSHA256=identity(text), familyId=family, role=role, intent=intent,
                    label=label, language=language, tokens=tokens, reason=basis,
                    synthetic=True, observedSMS=False, independentNativeReview=False,
                    predictionsUsed=False, accepted=reason is None))
                staged_signatures.update(signatures); staged_features.append(feat)
        seen.update(staged_signatures); features.extend(staged_features)
    if failures:
        # No partial admission or inference. Revisions, if needed, precede sealing.
        path = OUT / f'admission-failed-{len(list(OUT.glob("admission-failed-*.json"))) + 1}.json'
        write(path, {'failures': failures, 'authorSHA256': sha(Path(__file__).with_name('author_action_calibration_v66.py'))})
        print(json.dumps(failures, ensure_ascii=False, indent=2)); raise ValueError('authoring failed pre-inference audit')
    for role, rows in roles.items():
        assert len(rows) == 72
        path = EVAL / f'{NAME}-{role}.ndjson'
        with path.open('x') as f:
            for r in rows: f.write(json.dumps(r, ensure_ascii=False) + '\n')
    deps = [Path(__file__), Path(__file__).with_name('author_action_calibration_v66.py'),
            Path(__file__).with_name('action_calibration_v66.py'), BASE]
    write(OUT / 'admission.json', dict(decisions=decisions, filesSHA256={str(p.relative_to(ROOT)): sha(p) for p in deps},
        historicalFilesSHA256={str(p.relative_to(ROOT)): sha(p) for p in paths},
        roleFiles={role: str((EVAL / f'{NAME}-{role}.ndjson').relative_to(ROOT)) for role in roles},
        roleFilesSHA256={role: sha(EVAL / f'{NAME}-{role}.ndjson') for role in roles},
        roleCounts={role: dict(Counter(r['filterReview']['kind'] for r in rows)) for role, rows in roles.items()},
        approvedTraining=str((ROOT / base['training']).relative_to(ROOT)), approvedTrainingSHA256=sha(ROOT / base['training']),
        isolation='Exact/digit/template/semantic signatures and trigram Jaccard .65 against known local inputs; author-defined business families stay in one role. This does not prove source independence or absence of semantic correlation.',
        reviewer='Coding assistant content review; no independent native-speaker certification',
        sourceIndependentFinal=False, releaseEligible=False))
    print('Admitted 72 calibration + 72 development; 6 whole families each; no model predictions used.')


if __name__ == '__main__': main()
