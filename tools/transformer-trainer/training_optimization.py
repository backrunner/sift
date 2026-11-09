"""Inspectably group AdamW parameters without changing frozen weights."""
from __future__ import annotations

from collections import defaultdict
import math
import re


def parameter_groups(model, learning_rate: float, weight_decay: float, *,
                     policy: str = 'grouped', head_multiplier: float = 1.,
                     layer_decay: float = 1.) -> tuple[list, list]:
    if (policy not in ('legacy', 'grouped') or not math.isfinite(learning_rate)
            or learning_rate <= 0 or not math.isfinite(weight_decay) or weight_decay < 0
            or not math.isfinite(head_multiplier) or head_multiplier <= 0
            or not 0 < layer_decay <= 1):
        raise ValueError('invalid optimizer grouping configuration')
    named = [(n,p) for n,p in model.named_parameters() if p.requires_grad]
    if not named:
        raise ValueError('optimizer has no trainable parameters')
    indices = [int(m[1]) for n,_ in model.named_parameters()
               if (m := re.search(r'(?:^|\.)layers\.(\d+)\.', n))]
    top = max(indices, default=0)
    buckets = defaultdict(list)
    for name, parameter in named:
        rate, decay = learning_rate, weight_decay
        if policy == 'grouped':
            match = re.search(r'(?:^|\.)layers\.(\d+)\.', name)
            if match:
                rate *= layer_decay ** (top - int(match[1]))
            elif name.startswith(('head.', 'classifier.')):
                rate *= head_multiplier
            if parameter.ndim <= 1 or name.endswith('.bias'):
                decay = 0.
        buckets[(rate,decay)].append((name,parameter))
    groups, report = [], []
    for (rate,decay), entries in sorted(buckets.items()):
        groups.append({'params':[p for _,p in entries], 'lr':rate, 'weight_decay':decay})
        report.append({'learningRate':rate, 'weightDecay':decay,
            'tensorCount':len(entries),'parameterCount':sum(p.numel() for _,p in entries),
            'nameExamples':[n for n,_ in entries[:3]]})
    return groups, report


def update_plan(batch_count: int, epochs: int, accumulation: int, warmup_ratio: float) -> dict:
    if batch_count < 1 or epochs < 1 or accumulation < 1 or not 0 <= warmup_ratio < 1:
        raise ValueError('invalid optimizer update plan')
    updates = math.ceil(batch_count/accumulation)*epochs
    return {'plannedUpdates':updates,'warmupUpdates':int(updates*warmup_ratio),
            'updatesPerEpoch':math.ceil(batch_count/accumulation)}
