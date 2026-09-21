"""Compare real Classic artifact reports before replacing an accepted model."""

from __future__ import annotations

import math
import re


def require_non_regression(candidate: dict, baseline: dict) -> dict:
    """Fail closed on incomparable reports or any raw-label/action regression."""
    if candidate.get("suiteVersion") != 2 or baseline.get("suiteVersion") != 2:
        raise SystemExit("error: Classic comparison requires current artifact reports")
    for report in (candidate, baseline):
        if not re.fullmatch(r"[0-9a-f]{64}", str(report.get("modelSHA256", ""))):
            raise SystemExit("error: Classic comparison is missing artifact identity")
        threshold = report.get("confidenceThreshold")
        if isinstance(threshold, bool) or not isinstance(threshold, (int, float)) or not 0 <= threshold <= 1:
            raise SystemExit("error: Classic comparison has an invalid confidence threshold")
    if candidate["confidenceThreshold"] != baseline["confidenceThreshold"]:
        raise SystemExit("error: Classic comparison uses different confidence thresholds")
    if candidate.get("benignOrTransactionToJunk") != 0:
        raise SystemExit("error: Classic candidate routes benign/transaction messages to junk")

    deltas: dict[str, dict[str, float]] = {}
    failures: list[str] = []
    for suite in ("fixed", "promotion", "billing", "conversation"):
        expected_hash = baseline.get("datasetSHA256", {}).get(suite, "")
        if not re.fullmatch(r"[0-9a-f]{64}", str(expected_hash)) or candidate.get("datasetSHA256", {}).get(suite) != expected_hash:
            raise SystemExit(f"error: Classic {suite} comparison uses different or unidentified datasets")
        before, after = baseline.get(suite, {}), candidate.get(suite, {})
        count = before.get("count")
        if type(count) is not int or count <= 0 or after.get("count") != count:
            raise SystemExit(f"error: Classic {suite} comparison has inconsistent row counts")
        deltas[suite] = {}
        for metric in ("rawLabelAccuracy", "actionAccuracy"):
            scores = [before.get(metric), after.get(metric)]
            if any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 <= value <= 1 for value in scores):
                raise SystemExit(f"error: Classic {suite}.{metric} has invalid scores")
            delta = scores[1] - scores[0]
            deltas[suite][metric] = delta
            if delta < -1e-12:
                failures.append(f"{suite}.{metric}: {scores[0]:.4%} -> {scores[1]:.4%}")
    if failures:
        raise SystemExit("error: Classic regresses against the published baseline: " + "; ".join(failures))
    return {
        "passed": True,
        "baselineModelSHA256": baseline["modelSHA256"],
        "candidateModelSHA256": candidate["modelSHA256"],
        "datasetSHA256": candidate["datasetSHA256"],
        "deltas": deltas,
    }
