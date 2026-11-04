"""Shared Premium-model labels and ABI identifiers."""

ABSTAIN_LABEL = "__sift_abstain__"
MODEL_ABI_V1 = "sift-signal-v1"


def model_labels(taxonomy_labels: set[str]) -> set[str]:
    return taxonomy_labels | {ABSTAIN_LABEL}


def model_actions(taxonomy: dict) -> dict[str, str]:
    """Resolve leaf overrides before group defaults, including abstention."""
    return {ABSTAIN_LABEL: "none", **{
        leaf["id"]: leaf.get("systemAction", group["systemAction"])
        for group in taxonomy["groups"] for leaf in group["leaves"]
    }}
