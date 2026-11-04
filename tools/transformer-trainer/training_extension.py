"""Explicit budget extension: keep weights, Adam moments, RNG and anchor; replace only the schedule."""
import hashlib
from pathlib import Path
import random


SCHEDULE_FIELDS = frozenset({
    'learning_rate', 'warmup_ratio', 'num_epochs', 'convergence_patience',
    'convergence_min_updates', 'gradient_probe_every', 'convergence_require_training_plateau',
    'loss_tail_epochs', 'loss_tail_max_epochs', 'loss_tail_lr_ratio', 'loss_tail_patience',
})


def load_extension(path, model, optimizer, scheduler, generator, contract, device):
    import torch
    from loss_tail import LossTailScheduler
    if not isinstance(scheduler, LossTailScheduler):
        raise ValueError('schedule extension requires bounded loss-tail scheduling')
    path = Path(path)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if contract.get('extensionParent', {}).get('sha256') != digest:
        raise ValueError('extension parent state hash changed')
    state = torch.load(path, map_location='cpu', weights_only=True)
    parent, extra = state['contract'], state['extra']
    if state.get('schemaVersion') != 1 or extra.get('stopReason') not in ('max_updates', 'epoch_budget'):
        raise ValueError('extension requires a completed budget, not an interrupted or divergent run')
    if extra['step'] != extra['nextEpoch'] * parent['plan']['updatesPerEpoch']:
        raise ValueError('extension requires a complete parent epoch')
    if not extra.get('gradientProbeHistory') or extra['gradientProbeHistory'][-1]['step'] != extra['step']:
        raise ValueError('extension requires a terminal full-objective probe')
    for key in set(parent) | set(contract):
        if key not in ('arguments', 'plan', 'extensionParent') and parent.get(key) != contract.get(key):
            raise ValueError('extension invariant changed: ' + key)
    old_args, new_args = parent['arguments'], contract['arguments']
    for key in set(old_args) | set(new_args):
        if key not in SCHEDULE_FIELDS and old_args.get(key) != new_args.get(key):
            raise ValueError('extension method changed: ' + key)
    if parent['plan']['updatesPerEpoch'] != contract['plan']['updatesPerEpoch']:
        raise ValueError('extension changes epoch composition')
    parameters = {n: p for n, p in model.named_parameters() if p.requires_grad}
    if list(parameters) != list(state['parameters']):
        raise ValueError('extension trainable parameter order changed')
    for name, parameter in parameters.items():
        value = state['parameters'][name]
        if value.shape != parameter.shape or value.dtype != parameter.dtype or not torch.isfinite(value).all():
            raise ValueError('invalid extension parameters: ' + name)
    groups = optimizer.state_dict()['param_groups']
    old_groups = state['optimizer']['param_groups']
    clean = lambda g: {k: v for k, v in g.items() if k not in ('lr', 'initial_lr')}
    if len(groups) != len(old_groups) or any(clean(a) != clean(b) for a, b in zip(groups, old_groups)):
        raise ValueError('extension optimizer groups or hyperparameters changed')
    # Preserve the fresh, explicitly declared schedule while importing Adam's
    # existing per-parameter step/momentum. This is not an exact scheduler resume.
    schedule = scheduler.state_dict()
    with torch.no_grad():
        for name, parameter in parameters.items():
            parameter.copy_(state['parameters'][name].to(parameter.device))
    optimizer.load_state_dict(state['optimizer'])
    scheduler.load_state_dict(schedule)
    for group, rate in zip(optimizer.param_groups, scheduler.base_lrs):
        group['initial_lr'] = rate
    generator.set_state(state['generatorRNG'])
    torch.set_rng_state(state['torchRNG'])
    random.setstate(state['pythonRNG'])
    if device == 'mps':
        torch.mps.set_rng_state(state['mpsRNG'])
    if device == 'cuda':
        torch.cuda.set_rng_state_all(state['cudaRNG'])
    return {
        'parentStateSHA256': digest,
        'parentCompletedUpdates': extra['step'], 'parentCompletedEpochs': extra['nextEpoch'],
        'parentStopReason': extra['stopReason'], 'optimizerMomentsPreserved': True,
        'rngPreserved': True, 'originalParameterAnchorPreserved': True,
        'parentTerminalObjective': extra['gradientProbeHistory'][-1]['objective'],
        'newInitialLearningRates': scheduler.get_last_lr(),
        'selectionHistoryReset': True,
        'semantics': 'New bounded scheduling stage. Parent Adam moments, step counters, weights, RNG and original anchor preserved. Stage update/epoch counters restart at zero. Compare selected candidate with parent and retained checkpoints separately.',
    }
