"""Selection metrics for an explicitly separated, grouped development set."""
from __future__ import annotations

from collections import Counter


def macro_f1(pairs: list[tuple[str, str]]) -> float:
    """Macro F1 over the fixed gold-label support, not majority-class accuracy."""
    if not pairs:
        raise ValueError("validation requires nonempty gold data")
    expected = Counter(a for a, _ in pairs)
    predicted = Counter(b for _, b in pairs)
    correct = Counter(a for a, b in pairs if a == b)
    return sum(2 * correct[label] / (count + predicted[label])
               for label, count in expected.items()) / len(expected)


class EarlyStopping:
    def __init__(self, patience: int, minimum_delta: float = .002):
        if patience < 1 or minimum_delta < 0:
            raise ValueError("invalid early-stopping policy")
        self.patience = patience
        self.minimum_delta = minimum_delta
        self.best_score: float | None = None
        self.best_epoch: int | None = None
        self.stale_epochs = 0

    def update(self, epoch: int, score: float, *, eligible: bool = True) -> tuple[bool, bool]:
        if not 0 <= score <= 1:
            raise ValueError("invalid validation score")
        improved = eligible and (self.best_score is None or score > self.best_score + self.minimum_delta)
        if improved:
            self.best_score, self.best_epoch, self.stale_epochs = score, epoch, 0
        elif self.best_score is not None:
            self.stale_epochs += 1
        return improved, self.stale_epochs >= self.patience


def action_metrics(pairs: list[tuple[str,str]], actions: dict[str,str]) -> dict:
    if not pairs:
        raise ValueError('action metrics require development rows')
    normal=lambda label:actions[label] not in ('junk','promotion')
    spam=sum(actions[a]=='junk' for a,b in pairs)
    true_junk=sum(actions[a]==actions[b]=='junk' for a,b in pairs)
    nonspam_junk=sum(actions[a]!='junk' and actions[b]=='junk' for a,b in pairs)
    return {'actionAccuracy':sum(actions[a]==actions[b] for a,b in pairs)/len(pairs),
        'benignToJunk':sum(normal(a) and actions[b]=='junk' for a,b in pairs),
        'nonSpamToJunk':nonspam_junk,
        'promotionToJunk':sum(actions[a]=='promotion' and actions[b]=='junk' for a,b in pairs),
        'benignToPromotion':sum(normal(a) and actions[b]=='promotion' for a,b in pairs),
        'spamCount':spam,
        'spamRecall':true_junk/spam if spam else None,
        'spamPrecision':true_junk/(true_junk+nonspam_junk) if true_junk+nonspam_junk else None}


def require_export_selection(history: list[dict], *, early_stopping_enabled: bool) -> None:
    if early_stopping_enabled and not any(point['selected'] for point in history):
        raise ValueError('no eligible development epoch; refusing export/install, use --skip-export for research')


def selection_scores(pairs, actions, *, objective='macro-f1', maximum_nonspam_junk=None):
    """Return eligible ranking and diagnostic ranking; never relax eligibility.

    One recovered junk example outranks any change in fine macro F1. The
    diagnostic score first satisfies the FP cap, otherwise minimizes FP.
    Both scores fit EarlyStopping's [0, 1] contract. Use minimum_delta=0.
    """
    fine = macro_f1(pairs)
    if objective == 'macro-f1':
        return fine, fine
    if objective != 'junk-recall-then-macro-f1':
        raise ValueError('unknown validation selection objective')
    if not actions or maximum_nonspam_junk is None:
        raise ValueError('junk selection requires taxonomy actions and a nonspam FP cap')
    metrics = action_metrics(pairs, actions)
    spam = metrics['spamCount']
    if not spam:
        raise ValueError('junk selection requires junk development examples')
    true_junk = sum(actions[a] == actions[b] == 'junk' for a, b in pairs)
    rank = (true_junk + .5 * fine) / (spam + .5)
    false_junk = metrics['nonSpamToJunk']
    nonspam = len(pairs) - spam
    diagnostic = (.5 + .5 * rank if false_junk <= maximum_nonspam_junk else
                  .49 * ((nonspam - false_junk) + .25 * rank) / (nonspam + .25))
    return rank, diagnostic
