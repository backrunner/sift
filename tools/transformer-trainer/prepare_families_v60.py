"""Admit new authored families before scoring; preserve all frozen old inputs."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path

from approved_signal import ROOT, verify
from author_families_v60 import cases
from filter_policy import allowed_labels, identity, training_kind, validate_targets
from import_reviewed_public import keys
from junk_evidence import validate_junk_evidence
from prepare_approved_signal import quality_reason
from prepare_enrichment_v16 import suffixes
from public_group_isolation import shingles, similar
from retired_samples import RetiredSamples

NAME = 'signal-source-families-v60'
OUT = ROOT / 'build/signal-source-families-v60-20261101'
TRAIN = ROOT / 'tools/apple-trainer/Training'
EVAL = ROOT / 'tools/transformer-trainer/Evaluation'
BASE = TRAIN / 'signal-language-quality-v52.json'


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path): return [json.loads(l) for l in path.read_text().splitlines() if l]


def write(path, obj):
    with path.open('x') as stream: json.dump(obj, stream, ensure_ascii=False, indent=2); stream.write('\n')


def rows_file(path, rows):
    with path.open('x') as stream:
        for row in rows: stream.write(json.dumps(row, ensure_ascii=False) + '\n')


def main():
    if (OUT / 'admission.json').exists(): raise ValueError('admission already frozen')
    OUT.mkdir(parents=True, exist_ok=True)
    base = verify(BASE); old = read(ROOT / base['training'])
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(ROOT / 'build/signal-sam-retained-v33-20261029/sam-321/checkpoint',
                                             local_files_only=True)
    paths = sorted(set(TRAIN.glob('*.ndjson')) | set(EVAL.glob('*.ndjson'))
                   | set((ROOT / 'tools/apple-trainer/Evaluation').glob('*.ndjson'))
                   | {ROOT / p for p in base['filesSHA256'] if p.endswith('.ndjson')})
    texts = {r['text'] for path in paths for r in read(path)}
    suffix = suffixes(); suffix.tlds.update(('test', 'invalid', 'example'))
    features = [shingles(t, suffix) for t in sorted(texts)]
    seen = {identity(k) for t in texts for k in keys(t, family=True)}
    seen.update(base['protectedSignatureSHA256'])
    retired = RetiredSamples()
    admitted = {'train': [], 'development': []}; decisions = []; rejected = []
    # Preassigned development comes first; no model score determines membership.
    for role, family, normal, variants in sorted(cases()):
        staged = []; failures = []; signatures = set(); staged_features = []
        for label, translations in zip((normal, 'promotion', 'spam'), variants, strict=True):
            for lang, text in zip(('zh', 'en', 'ja'), translations, strict=True):
                text = text.format(url=f'https://{family}.invalid/status')
                row = {'text': text, 'label': label, 'language': lang,
                       'source': f'authored-reviewed-v60:{family}:{label}'}
                sig = {identity(k) for k in keys(text, family=True)}
                feat = shingles(text, suffix); tokens = len(tokenizer(text)['input_ids'])
                reason = quality_reason(row) or retired.reason(row)
                if tokens > 96: reason = 'evidence-exceeds-96-token-input'
                elif sig & (seen | signatures): reason = 'historical-or-local-signature-overlap'
                elif any(similar(feat, old_feat) for old_feat in features): reason = 'near-historical-or-other-family'
                if reason: failures.append({'textSHA256': identity(text), 'language': lang, 'label': label,
                                            'reason': reason, 'tokens': tokens})
                staged.append((row, tokens)); signatures.update(sig); staged_features.append(feat)
        if failures:
            rejected.append({'family': family, 'role': role, 'failures': failures,
                             'allTextSHA256': [identity(r['text']) for r, _ in staged]})
            continue
        seen.update(signatures); features.extend(staged_features)
        for row, tokens in staged:
            kind = training_kind(row['label'])
            reason = {'normal': 'Specific existing request, contract, claim or service event; no new optional purchase or credential exfiltration.',
                      'commercial': 'Optional new paid product/service, explicit offer without a harmful mechanism.',
                      'harmful': 'Explicit bank credential/remote-control exfiltration, concealed money forwarding, gift-card collection, advance-fee deception, or recruitment-fee pyramid in the SMS body.'}[kind]
            item = {'textSHA256': identity(row['text']), 'role': role, 'familyId': family,
                    'label': row['label'], 'language': row['language'], 'source': row['source'],
                    'tokenCount': tokens, 'acquisitionKind': 'synthetic', 'observedSMS': False,
                    'independentNativeReview': False, 'goldReviewWithoutPredictions': True,
                    'decision': 'accepted', 'reason': reason}
            decisions.append(item)
            if role == 'development':
                row['filterReview'] = {'kind': kind, 'inputForm': 'sms-text', 'basis': reason,
                    'originalLabelPreserved': True, 'reviewedTextSHA256': identity(row['text']), 'fineLabelScored': True}
            admitted[role].append(row)
    if len(admitted['train']) < 27 or len(admitted['development']) < 18:
        write(OUT / 'admission-failed.json', {'counts': {k: len(v) for k, v in admitted.items()}, 'rejected': rejected})
        raise ValueError('insufficient intact families; no inference/training allowed')
    additions = TRAIN / (NAME + '-additions.ndjson'); rows_file(additions, admitted['train'])
    development = EVAL / (NAME + '-authored-development.ndjson'); rows_file(development, admitted['development'])
    review = TRAIN / (NAME + '-review.json')
    write(review, {'kind': 'pre-inference-authored-family-review', 'decisions': decisions,
                  'rejectedWholeFamilies': rejected, 'authorSourceSHA256': sha(Path(__file__).with_name('author_families_v60.py')),
                  'reviewer': 'Coding assistant, not independent native-speaker annotation',
                  'inputPurpose': 'Synthetic training candidates and disjoint synthetic development; no real-final claim',
                  'modelPredictionsUsedForGoldOrRole': False})
    protected = set(base['protectedSignatureSHA256'])
    for row in admitted['development']: protected.update(identity(k) for k in keys(row['text'], family=True))
    manifests = {}
    for arm in ('control', 'data'):
        rows = old + (admitted['train'] if arm == 'data' else [])
        assert (len(rows) + 127) // 128 == 28
        training = TRAIN / (NAME + '-' + arm + '.ndjson'); rows_file(training, rows)
        target = deepcopy(json.loads((ROOT / base['filterTargetReview']).read_text()))
        target['trainingSHA256'] = sha(training)
        for row in admitted['train'] if arm == 'data' else []:
            kind = training_kind(row['label'])
            target['entries'][identity(row['text'])] = {k: row[k] for k in ('label', 'language', 'source')}
            target['entries'][identity(row['text'])].update(kind=kind, allowedLabels=allowed_labels(row['label'], kind),
                reviewBasis='Frozen v60 assistant-authored family review before inference')
        validate_targets(rows, target)
        targets_path = TRAIN / (NAME + '-' + arm + '-targets.json'); write(targets_path, target)
        junk = deepcopy(json.loads((ROOT / base['junkEvidenceReview']).read_text()))
        junk['inputSHA256'] = sha(training)
        for row in admitted['train'] if arm == 'data' else []:
            if row['label'] != 'spam': continue
            decision = next(d for d in decisions if d['textSHA256'] == identity(row['text']))
            junk['decisions'].append({'textSHA256': identity(row['text']), 'source': row['source'],
                'language': row['language'], 'originalLabel': 'spam', 'decision': 'retain', 'evidenceKind': 'body',
                'visibleCharacterEnd': len(row['text']), 'fullTokenCount': decision['tokenCount'],
                'supportSpans': [[0, len(row['text'])]], 'reason': decision['reason']})
        validate_junk_evidence(rows, junk)
        junk_path = TRAIN / (NAME + '-' + arm + '-junk-evidence.json'); write(junk_path, junk)
        deps = [training, additions, development, targets_path, junk_path, review, Path(__file__),
                Path(__file__).with_name('author_families_v60.py')]
        manifest = {**base, 'dataRevision': NAME + '-' + arm, 'training': str(training.relative_to(ROOT)),
            'trainingCount': len(rows), 'development': str(development.relative_to(ROOT)),
            'developmentCount': len(admitted['development']), 'qualityReport': str(review.relative_to(ROOT)),
            'filterTargetReview': str(targets_path.relative_to(ROOT)), 'junkEvidenceReview': str(junk_path.relative_to(ROOT)),
            'protectedSignatureSHA256': sorted(protected), 'newDevelopmentIsIndependentFinal': False,
            'revisionNote': 'Pre-inference authored candidates; old train/dev unchanged; no default activation or training yet.',
            'filesSHA256': {**base['filesSHA256'], **{str(p.relative_to(ROOT)): sha(p) for p in deps}}}
        path = TRAIN / (NAME + '-' + arm + '.json'); write(path, manifest); verify(path)
        manifests[arm] = {'path': str(path.relative_to(ROOT)), 'sha256': sha(path)}
    write(OUT / 'admission.json', {'schemaVersion': 1, 'manifests': manifests,
        'newTrainingRows': len(admitted['train']), 'newAuthoredDevelopmentRows': len(admitted['development']),
        'familyCounts': {role: len({d['familyId'] for d in decisions if d['role'] == role}) for role in admitted},
        'rejectedWholeFamilies': rejected, 'allHistoricalPathsSHA256': {str(p.relative_to(ROOT)): sha(p) for p in paths},
        'authorSourceSHA256': sha(Path(__file__).with_name('author_families_v60.py')),
        'sourceSHA256': sha(Path(__file__)), 'oldTrainingSHA256': sha(ROOT / base['training']),
        'allNewEvidenceVisibleAt96Tokens': True, 'strictCoveragePassed': True,
        'newObservedSMS': 0, 'newIndependentFinal': False, 'newModelScored': False, 'releaseEligible': False,
        'nextStep': 'Training-side difficulty screening only after this review is frozen; do not tune or relabel the development rows.'})
    print(json.dumps({'train': len(admitted['train']), 'development': len(admitted['development']), 'rejected': rejected}, ensure_ascii=False))


if __name__ == '__main__': main()
