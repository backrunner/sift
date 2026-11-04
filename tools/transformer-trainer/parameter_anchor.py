"""L2-SP around the stage's initial weights, including exact-resume identity."""
import hashlib


class ParameterAnchor:
    def __init__(self, model, coefficient):
        import math
        if not math.isfinite(coefficient) or coefficient < 0:
            raise ValueError('anchor coefficient must be finite and nonnegative')
        self.coefficient = coefficient
        self.parameters = [(name, p, p.detach().clone()) for name, p in model.named_parameters()
                           if p.requires_grad] if coefficient else []

    def penalty(self):
        import torch
        return .5 * self.coefficient * torch.stack([
            (p - initial).float().square().sum() for _, p, initial in self.parameters]).sum()

    def sha256(self):
        if not self.parameters:
            return None
        digest = hashlib.sha256()
        for name, _, initial in self.parameters:
            digest.update(name.encode())
            digest.update(initial.cpu().contiguous().numpy().tobytes())
        return digest.hexdigest()
