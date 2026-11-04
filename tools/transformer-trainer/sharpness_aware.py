"""SAM parameter perturbations around an accumulated, unclipped objective.

The caller owns both backward passes and the single base-optimizer step.
Restoration uses exact copies, including when the second pass raises.
"""
from contextlib import contextmanager
import math


def validate_sam_model(model, rho, rdrop_alpha=0.):
    import torch
    if not math.isfinite(rho) or rho < 0:
        raise ValueError('SAM rho must be finite and nonnegative')
    if not rho:
        return
    if rdrop_alpha or any(isinstance(m, torch.nn.modules.dropout._DropoutNd) and m.p
                          for m in model.modules()):
        raise ValueError('SAM currently requires deterministic dropout-free forwards')
    config = getattr(model, 'config', None)
    for field in ('attention_dropout', 'embedding_dropout', 'mlp_dropout', 'classifier_dropout'):
        if getattr(config, field, 0):
            raise ValueError('SAM requires zero '+field)


@contextmanager
def sam_perturbation(parameters, rho):
    import torch
    if not math.isfinite(rho) or rho <= 0:
        raise ValueError('SAM perturbation requires a positive finite rho')
    active = [p for p in parameters if p.requires_grad and p.grad is not None]
    if not active:
        raise ValueError('SAM requires accumulated gradients')
    norm = torch.linalg.vector_norm(torch.stack([
        torch.linalg.vector_norm(p.grad.detach().float()) for p in active]))
    if not bool(torch.isfinite(norm)):
        raise ValueError('Non-finite SAM ascent gradient')
    originals = []
    try:
        with torch.no_grad():
            for parameter in active:
                original = parameter.detach().clone()
                originals.append((parameter, original))
                parameter.add_(parameter.grad * (rho / norm.clamp_min(1e-12)))
        yield float(norm.detach().cpu())
    finally:
        with torch.no_grad():
            for parameter, original in originals:
                parameter.copy_(original)


def prune_epoch_archives(folder, current_epoch, selected_epoch):
    """Only generated epoch-NNN.pt files in this trial; keep best plus latest."""
    keep = {current_epoch, selected_epoch}
    removed = []
    for path in folder.glob('epoch-*.pt'):
        token = path.stem.removeprefix('epoch-')
        if token.isdecimal() and int(token) not in keep:
            if path.is_symlink():
                raise ValueError('Refusing to prune a symlinked epoch archive')
            path.unlink()
            removed.append(path.name)
    return removed
