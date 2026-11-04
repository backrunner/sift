"""Preserve a frozen checkpoint on replay rows while learning reviewed corrections."""

from __future__ import annotations


def is_reviewed_correction(source: str, prefixes: list[str]) -> bool:
    return any(source.startswith(prefix) for prefix in prefixes)


def correction_loss_weights(weights, correction_mask, multiplier: float):
    import torch

    if multiplier < 1:
        raise ValueError("correction loss multiplier must be at least 1")
    return torch.where(correction_mask, weights * multiplier, weights)


def validate_replay_contract(student_labels: list[str], teacher_labels: list[str],
                             student_tokenizer, teacher_tokenizer) -> None:
    if student_labels != teacher_labels:
        raise ValueError("replay teacher label order must exactly match the student")
    if (student_tokenizer.get_vocab() != teacher_tokenizer.get_vocab()
            or student_tokenizer.special_tokens_map != teacher_tokenizer.special_tokens_map):
        raise ValueError("replay teacher tokenizer must exactly match the student")


def replay_distillation_loss(student_logits, teacher_logits, labels, correction_mask,
                             alpha: float, temperature: float, label_smoothing: float = 0.,
                             only_correct_teacher: bool = False,
                             agreement_all_rows: bool = False,
                             hard_label_mode: str = 'mixed',
                             focal_gamma: float = 0.):
    """Return per-row loss; the teacher never vetoes reviewed correction rows.

    Replay rows combine hard-label CE with a frozen teacher's soft distribution.
    Correction rows use only hard-label CE, even if the teacher is confidently
    wrong. Keeping this dimension allows existing source weights to apply once.
    """
    import torch
    import torch.nn.functional as functional

    if not 0 <= alpha <= 1 or temperature < 1:
        raise ValueError("replay alpha must be in [0, 1] and temperature at least 1")
    if agreement_all_rows and not only_correct_teacher:
        raise ValueError('all-row agreement requires a correct-teacher gate')
    if hard_label_mode not in ('mixed','uniform'):
        raise ValueError('unsupported replay hard-label mode')
    if hard_label_mode=='uniform' and not only_correct_teacher:
        raise ValueError('uniform hard labels require a correct-teacher gate')
    from hard_label_loss import supervised_loss
    hard = supervised_loss(student_logits, labels, label_smoothing=label_smoothing,
                           focal_gamma=focal_gamma)
    soft = functional.kl_div(
        functional.log_softmax(student_logits / temperature, dim=-1),
        functional.softmax(teacher_logits.detach() / temperature, dim=-1),
        reduction="none",
    ).sum(dim=-1) * temperature ** 2
    # Optional retention study: ownership still records corrections, but a
    # teacher that agrees with reviewed gold can regularize these rows too.
    hard_only = torch.zeros_like(correction_mask) if agreement_all_rows else correction_mask
    if only_correct_teacher:
        hard_only = hard_only | (teacher_logits.detach().argmax(dim=-1) != labels)
    # Uniform CE changes only the agreement rows' hard-label coefficient.
    # It preserves disagreement CE=1 and agreement KD=alpha; it is deliberately
    # not renormalized, since that would also alter the other two coefficients.
    hard_coefficient=1. if hard_label_mode=='uniform' else 1-alpha
    return torch.where(hard_only, hard, hard_coefficient * hard + alpha * soft)
