#!/usr/bin/env python3
"""Describe source-matched generalization gaps without fitting or rescoring a final test.

Reads frozen training/development predictions. Reports contain counts and hashes,
never message bodies. Token lengths use the frozen tokenizer with no truncation.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re

from curate_dataset import detect_language
from generalization_validation import macro_f1
from model_contract import model_actions


def cohort(row: dict) -> str:
    source = row.get('source', '')
    for name in ('nus-en', 'nus-zh', 'vietnamese-train'):
        if source.endswith(':' + name):
            return name
    if source.startswith('augmentation:boundary:signal-v63:'):
        return 'authored-v63'
    if source.startswith('augmentation:boundary:signal-v64:'):
        return 'derived-v64'
    if source.startswith('synthetic:'):
        return 'historical-synthetic'
    if source == 'conversation-training.ndjson':
        return 'historical-conversation'
    if source.startswith(('public-reviewed-', 'signal-reviewed-v2:')):
        return 'reviewed-legacy-public'
    return 'historical-other-authored'


def language(row: dict) -> str:
    if row.get('language'):
        return row['language']
    source = row.get('source', '')
    if source.endswith(':nus-en'):
        return 'en'
    if source.endswith(':nus-zh'):
        return 'zh'
    if 'vietnamese' in source or source.startswith('augmentation:boundary:signal-v64:'):
        return 'vi'
    if source.startswith('synthetic:'):
        return source.split(':')[1]
    return detect_language(row['text'])


def read(path: Path) -> list[dict]:
    value = path.read_text()
    if value.lstrip().startswith('['):
        return json.loads(value)
    return [json.loads(line) for line in value.splitlines() if line]


def attach(rows: list[dict], predictions: list[dict], initial: list[dict] | None,
           lengths: list[int]) -> list[dict]:
    if len(rows) != len(predictions) or len(rows) != len(lengths) or (initial is not None and len(initial) != len(rows)):
        raise ValueError('dataset/prediction length mismatch')
    result = []
    for i, (row, prediction, length) in enumerate(zip(rows, predictions, lengths)):
        for p in [prediction, *([initial[i]] if initial is not None else [])]:
            if (p['text'], p['label']) != (row['text'], row['label']):
                raise ValueError('prediction text/gold differs from frozen row')
        result.append({**row, 'prediction': prediction['prediction'],
            'correct': prediction['prediction'] == row['label'],
            'confidence': prediction['confidence'], 'cohort': cohort(row),
            'language': language(row), 'tokens': length,
            'initialCorrect': initial[i]['prediction'] == row['label'] if initial is not None else None})
    return result


def metrics(rows: list[dict], actions: dict[str, str], max_length: int = 96) -> dict:
    if not rows:
        return {'count': 0}
    return {'count': len(rows), 'correct': sum(r['correct'] for r in rows),
        'accuracy': sum(r['correct'] for r in rows)/len(rows),
        'macroF1': macro_f1([(r['label'], r['prediction']) for r in rows]),
        'initialAccuracy': sum(r['initialCorrect'] for r in rows)/len(rows)
            if all(r['initialCorrect'] is not None for r in rows) else None,
        'actionCorrect': sum(actions[r['label']] == actions[r['prediction']] for r in rows),
        'truncated': sum(r['tokens'] > max_length for r in rows),
        'meanTokens': sum(r['tokens'] for r in rows)/len(rows),
        'highConfidenceErrors': sum(not r['correct'] and r['confidence'] >= .9 for r in rows)}


def matched_gap(training: list[dict], development: list[dict], actions: dict[str, str], fields: tuple[str, ...]) -> dict:
    buckets = defaultdict(list)
    for row in training:
        buckets[tuple(row[f] for f in fields)].append(row)
    matched, missing, weighted = [], [], 0.
    counts = Counter(tuple(r[f] for f in fields) for r in development)
    for key, count in counts.items():
        train = buckets.get(key, [])
        if not train:
            missing.append({'cell': list(key), 'developmentRows': count})
            continue
        matched.extend(r for r in development if tuple(r[f] for f in fields) == key)
        weighted += count * sum(r['correct'] for r in train)/len(train)
    dev_accuracy = sum(r['correct'] for r in matched)/len(matched) if matched else None
    return {'fields': fields, 'matchedDevelopmentRows': len(matched), 'missingCells': missing,
        'trainingAccuracyReweightedToDevelopmentCells': weighted/len(matched) if matched else None,
        'developmentAccuracyOnMatchedCells': dev_accuracy,
        'residualGap': weighted/len(matched)-dev_accuracy if matched else None,
        'note': 'Descriptive reweighting; does not establish causality or equalize within-cell difficulty.'}


def audit(training: list[dict], development: list[dict], actions: dict[str, str], max_length: int = 96) -> dict:
    result = {'schemaVersion': 1, 'training': {}, 'development': {},
        'matchedGaps': [matched_gap(training, development, actions, fields) for fields in
            [('label',), ('cohort', 'language'), ('cohort', 'language', 'label')]]}
    for name, rows in [('training', training), ('development', development)]:
        output = result[name]
        output['overall'] = metrics(rows, actions, max_length)
        for field in ('cohort', 'language', 'label'):
            output[field] = {key: metrics([r for r in rows if r[field] == key], actions, max_length)
                             for key in sorted({r[field] for r in rows})}
        output['length'] = {key: metrics([r for r in rows if (r['tokens'] > max_length) == long], actions, max_length)
                            for key, long in [('fits', False), ('truncated', True)]}
        output['confusions'] = [{'gold': a, 'prediction': b, 'count': n,
            'sameAction': actions[a] == actions[b]} for (a,b), n in
            Counter((r['label'], r['prediction']) for r in rows if not r['correct']).most_common()]
        output['errorsByActionBoundary'] = dict(Counter('within-action' if actions[r['label']] == actions[r['prediction']]
            else 'across-action' for r in rows if not r['correct']))
        output['vietnameseCurrencyArtifacts'] = sum(r['language'] == 'vi' and bool(re.search(r'\$\d', r['text'])) for r in rows)
        output['vietnameseDollarPlusDong'] = sum(r['language'] == 'vi' and bool(re.search(r'\$[\d,.]+\s*(?:đồng|dong)', r['text'], re.I)) for r in rows)
    return result


def training_policy_findings(rows: list[dict]) -> list[dict]:
    """Narrow, inspectable rules from docs/TAXONOMY.md; never relabel rows.

    This deliberately omits generic debit/balance/loan keywords whose primary
    intent needs context. These are review findings, not an automatic labeler.
    """
    rules = [
        ('merchant-outflow', 'finance.consumption',
         r"merchant purchase|spent from account .*in-store merchant|Account ending .* was charged .* by |was debited (?:[$£€]\s*)?[\d,.]+ at [A-Za-z][A-Za-z &'\-]+(?:;|\.)|POS\s*消费|发生商户消费|交易渠道为线下商户|加盟店利用|店舗決済で"),
        ('credited-inflow', 'finance.income',
         r'Balance update: .* credited to account ending|账户余额变动提醒[：:]\s*入账|円の入金がありました'),
    ]
    findings = []
    for row in rows:
        if row['label'] != 'finance.bank':
            continue
        for rule, proposed, pattern in rules:
            if re.search(pattern, row['text'], re.I):
                findings.append({'textSHA256': hashlib.sha256(row['text'].encode()).hexdigest(),
                    'source': row.get('source', ''), 'oldLabel': row['label'],
                    'proposedLabel': proposed, 'rule': rule,
                    'reviewBasis': 'docs/TAXONOMY.md fund-direction rule; not model predictions',
                    'applied': False})
    return findings


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--directory', type=Path, required=True)
    p.add_argument('--tokenizer', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(args.tokenizer, local_files_only=True)
    root = Path(__file__).resolve().parents[2]
    taxonomy = json.loads((root/'packages/taxonomy/taxonomy.json').read_text())
    actions = model_actions(taxonomy)
    inputs, datasets = [], {}
    for name, file in [('training', 'train.ndjson'), ('development', 'development.ndjson')]:
        paths = [args.directory/file, args.directory/(name+'-checkpoint-predictions.json'),
                 args.directory/(name+'-initialization-predictions.json')]
        rows, predictions = read(paths[0]), read(paths[1])
        initial = read(paths[2]) if paths[2].exists() else None
        lengths = [len(ids) for ids in tokenizer([r['text'] for r in rows], truncation=False)['input_ids']]
        datasets[name] = attach(rows, predictions, initial, lengths)
        inputs.extend(path for path in paths if path.exists())
    result = audit(datasets['training'], datasets['development'], actions)
    result['trainingPolicyFindings'] = training_policy_findings(datasets['training'])
    result['filesSHA256'] = {str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('training','development','filesSHA256')},indent=2))
    for name in ('training','development'):
        print(name, json.dumps(result[name]['cohort'], indent=2))


if __name__ == '__main__':
    main()
