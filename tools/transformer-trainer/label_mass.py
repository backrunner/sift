"""Keep label priors constant when ablating a subset of training examples."""
from collections import Counter
import hashlib
import json
from pathlib import Path


def preserving_weights(rows, reference_path):
    path = Path(reference_path)
    payload = path.read_bytes()
    reference = [json.loads(line) for line in payload.decode().splitlines() if line]
    original = {r['text']: r['label'] for r in reference}
    if len(original) != len(reference) or len({r['text'] for r in rows}) != len(rows):
        raise ValueError('label-mass ablation requires unique examples')
    if any(original.get(r['text']) != r['label'] for r in rows):
        raise ValueError('ablation must be a label-preserving subset of its reference')
    before = Counter(r['label'] for r in reference)
    after = Counter(r['label'] for r in rows)
    if before.keys() != after.keys():
        raise ValueError('ablation removed an entire label')
    weights = {label: before[label] / after[label] for label in before}
    if max(weights.values()) > 4:
        raise ValueError('label-mass compensation exceeds 4x')
    return weights, {'referenceSHA256': hashlib.sha256(payload).hexdigest(),
                     'referenceCounts': dict(before), 'activeCounts': dict(after),
                     'weights': weights,
                     'semantics': 'Preserves full-corpus per-label loss mass; minibatch ratios and within-label source diversity still differ.'}
