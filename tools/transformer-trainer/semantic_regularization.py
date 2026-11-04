"""Training-only action hierarchy and R-Drop; exported classifier stays linear.

This is an additive action/leaf parameterization, not an implementation of HGCLR.
No label ids, tokenizer, encoder dimensions or runtime ABI change.
"""
import torch
from torch import nn
from torch.nn import functional as F


class ActionResidualClassifier(nn.Module):
    def __init__(self, leaf, action_ids):
        super().__init__()
        if not isinstance(leaf, nn.Linear) or len(action_ids) != leaf.out_features:
            raise ValueError('action hierarchy requires a linear leaf classifier and complete mapping')
        if sorted(set(action_ids)) != list(range(max(action_ids) + 1)):
            raise ValueError('action ids must be contiguous')
        self.leaf = leaf
        self.action = nn.Linear(leaf.in_features, max(action_ids) + 1,
                                device=leaf.weight.device, dtype=leaf.weight.dtype)
        nn.init.zeros_(self.action.weight)
        nn.init.zeros_(self.action.bias)
        self.register_buffer('action_ids', torch.tensor(action_ids, device=leaf.weight.device))
        self.latest_action_logits = None

    def forward(self, features):
        self.latest_action_logits = self.action(features)
        return self.leaf(features) + self.latest_action_logits[..., self.action_ids]

    def fold(self):
        """Exact affine identity, subject only to floating point reassociation."""
        result = nn.Linear(self.leaf.in_features, self.leaf.out_features, bias=True,
                           device=self.leaf.weight.device, dtype=self.leaf.weight.dtype)
        with torch.no_grad():
            result.weight.copy_(self.leaf.weight + self.action.weight[self.action_ids])
            result.bias.copy_(self.action.bias[self.action_ids])
            if self.leaf.bias is not None:
                result.bias.add_(self.leaf.bias)
        return result


def symmetric_kl(first, second):
    """Per-row bidirectional KL, with gradients through both distributions."""
    log_first, log_second = F.log_softmax(first.float(), -1), F.log_softmax(second.float(), -1)
    return .5 * ((log_first.exp() - log_second.exp()) * (log_first - log_second)).sum(-1)


def action_cross_entropy(head, labels):
    if not isinstance(head, ActionResidualClassifier) or head.latest_action_logits is None:
        raise ValueError('action supervision requires an action residual forward pass')
    return F.cross_entropy(head.latest_action_logits, head.action_ids[labels], reduction='none')
