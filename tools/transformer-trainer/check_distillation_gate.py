#!/usr/bin/env python3
"""Compare a distilled candidate with its teacher's external holdout report.

The gate uses absolute accuracy loss, not relative percentage loss: a student
may not fall more than ``--max-loss`` on any fixed, promotion, billing/card,
conversation, action, or per-language metric.  Safety invariants such as
finite probabilities and zero benign-to-junk actions remain hard failures.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


QUALITY_PATHS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("fixedAccuracy", ("metrics", "fixedAccuracy")),
    ("promotionAccuracy", ("metrics", "promotionAccuracy")),
    ("billingAccuracy", ("metrics", "billingAccuracy")),
    ("conversationAccuracy", ("metrics", "conversationAccuracy")),
    ("fixedActionAccuracy", ("messageFilterActions", "fixedAccuracy")),
    ("promotionActionAccuracy", ("messageFilterActions", "promotionAccuracy")),
    ("billingActionAccuracy", ("metrics", "billingActionAccuracy")),
    ("conversationActionAccuracy", ("metrics", "conversationActionAccuracy")),
)


def read_report(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"error: could not read report {path}: {error}") from error
    if not isinstance(document, dict):
        raise SystemExit(f"error: report must contain a JSON object: {path}")
    return document


def nested_value(document: dict[str, Any], path: tuple[str, ...]) -> Any:
    value: Any = document
    for key in path:
        if not isinstance(value, dict) or key not in value:
            return None
        value = value[key]
    return value


def compare_reports(teacher: dict[str, Any], student: dict[str, Any], max_loss: float = 0.02) -> dict[str, Any]:
    if max_loss < 0:
        raise ValueError("max_loss must be non-negative")
    metrics: dict[str, dict[str, float | bool]] = {}
    failures: list[str] = []
    for name, path in QUALITY_PATHS:
        teacher_value = nested_value(teacher, path)
        student_value = nested_value(student, path)
        if not isinstance(teacher_value, (int, float)) or not isinstance(student_value, (int, float)):
            failures.append(f"missing metric: {name}")
            continue
        delta = float(student_value) - float(teacher_value)
        metrics[name] = {
            "teacher": float(teacher_value),
            "student": float(student_value),
            "delta": delta,
            "loss": max(0.0, -delta),
            "passed": delta >= -max_loss,
        }
        if delta + 1e-12 < -max_loss:
            failures.append(f"{name} loss {(-delta):.4f} exceeds {max_loss:.4f}")

    teacher_languages = nested_value(teacher, ("metrics", "languageAccuracy")) or {}
    student_languages = nested_value(student, ("metrics", "languageAccuracy")) or {}
    if not isinstance(teacher_languages, dict) or not isinstance(student_languages, dict):
        failures.append("missing metric: languageAccuracy")
    else:
        for language in sorted(set(teacher_languages) | set(student_languages)):
            teacher_value = teacher_languages.get(language)
            student_value = student_languages.get(language)
            name = f"languageAccuracy.{language}"
            if not isinstance(teacher_value, (int, float)) or not isinstance(student_value, (int, float)):
                failures.append(f"missing metric: {name}")
                continue
            delta = float(student_value) - float(teacher_value)
            metrics[name] = {
                "teacher": float(teacher_value),
                "student": float(student_value),
                "delta": delta,
                "loss": max(0.0, -delta),
                "passed": delta >= -max_loss,
            }
            if delta + 1e-12 < -max_loss:
                failures.append(f"{name} loss {(-delta):.4f} exceeds {max_loss:.4f}")

    if nested_value(student, ("metrics", "probabilitiesFinite")) is not True:
        failures.append("student probabilitiesFinite is not true")
    if nested_value(student, ("metrics", "probabilitySumsValid")) is not True:
        failures.append("student probabilitySumsValid is not true")
    if nested_value(student, ("messageFilterActions", "benignOrTransactionToJunk")) != 0:
        failures.append("student benignOrTransactionToJunk is non-zero")
    readable_cases = nested_value(student, ("messageFilterActions", "readableCases"))
    if not isinstance(readable_cases, list) or not readable_cases:
        failures.append("student readable message-filter cases are missing")
    elif any(case.get("passed") is not True for case in readable_cases if isinstance(case, dict)):
        failures.append("student readable message-filter case failed")
    teacher_false_positive_rate = nested_value(teacher, ("messageFilterActions", "promotionFalsePositiveRate"))
    student_false_positive_rate = nested_value(student, ("messageFilterActions", "promotionFalsePositiveRate"))
    if isinstance(teacher_false_positive_rate, (int, float)) and isinstance(student_false_positive_rate, (int, float)):
        if float(student_false_positive_rate) > float(teacher_false_positive_rate) + 1e-12:
            failures.append("student promotionFalsePositiveRate increased")

    return {
        "schemaVersion": 1,
        "maxAbsoluteLoss": max_loss,
        "passed": not failures,
        "metrics": metrics,
        "failures": failures,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teacher-report", type=Path, required=True)
    parser.add_argument("--student-report", type=Path, required=True)
    parser.add_argument("--max-loss", type=float, default=0.02)
    parser.add_argument("--out", type=Path, default=None)
    arguments = parser.parse_args()
    result = compare_reports(
        read_report(arguments.teacher_report.expanduser().resolve()),
        read_report(arguments.student_report.expanduser().resolve()),
        arguments.max_loss,
    )
    rendered = json.dumps(result, indent=2, ensure_ascii=False)
    if arguments.out is not None:
        output = arguments.out.expanduser().resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered + "\n", encoding="utf-8")
        print(f"gate report: {output}")
    print(rendered)
    if not result["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
