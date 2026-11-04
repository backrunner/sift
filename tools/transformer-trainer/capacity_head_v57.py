"""Training-only exact-label head warmup before grouped-policy adaptation."""


def warm_linear(features, labels, weights, label_to_id, steps=500, lr=.02):
    import torch
    if (features.ndim != 2 or len(features) != len(labels) or len(labels) != len(weights)
            or not torch.isfinite(features).all() or not torch.isfinite(weights).all()
            or bool((weights <= 0).any()) or steps < 1):
        raise ValueError('invalid warmup inputs')
    x, y, w = features.double().cpu(), labels.long().cpu(), weights.double().cpu()
    if set(y.tolist()) != set(label_to_id.values()):
        raise ValueError('every classifier output needs an exact-label training signal')
    head = torch.nn.Linear(x.shape[1], len(label_to_id), bias=True, dtype=torch.float64)
    with torch.no_grad(): head.weight.zero_(); head.bias.zero_()
    optimizer = torch.optim.AdamW([{'params': [head.weight], 'weight_decay': .01},
                                  {'params': [head.bias], 'weight_decay': 0.}], lr=lr)
    history = []
    for step in range(steps + 1):
        optimizer.zero_grad(set_to_none=True)
        logits = head(x)
        loss = (torch.nn.functional.cross_entropy(logits, y, reduction='none') * w).sum() / w.sum()
        loss.backward()
        norm = torch.sqrt(sum(p.grad.square().sum() for p in head.parameters()))
        if not torch.isfinite(loss) or not torch.isfinite(norm): raise ValueError('nonfinite warmup')
        if step % 50 == 0 or step == steps:
            history.append({'step': step, 'exactLabelWeightedDataLoss': float(loss.detach()),
                            'gradientNorm': float(norm), 'rawFineCorrect': int((logits.argmax(-1) == y).sum()),
                            'rows': len(y)})
        if step < steps: optimizer.step()
    a, b = label_to_id['promotion'], label_to_id['carrier.promotion']
    if torch.equal(head.weight[a], head.weight[b]) and torch.equal(head.bias[a], head.bias[b]):
        raise ValueError('promotion outputs remain indistinguishable')
    return {k: v.detach().float().clone() for k, v in head.state_dict().items()}, history
