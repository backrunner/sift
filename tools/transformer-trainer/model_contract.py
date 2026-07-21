"""Shared Premium-model labels and ABI identifiers."""

ABSTAIN_LABEL = "__sift_abstain__"
MODEL_ABI_V1 = "sift-signal-v1"


def model_labels(taxonomy_labels: set[str]) -> set[str]:
    return taxonomy_labels | {ABSTAIN_LABEL}
