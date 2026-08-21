#!/usr/bin/env python3
"""Compare a distilled candidate with its teacher's external holdout report.

The gate uses absolute accuracy loss, not relative percentage loss: a student
may not fall more than ``--max-loss`` on any fixed, promotion, billing/card,
conversation, action, or per-language metric.  Safety invariants such as
finite probabilities and zero benign-to-junk actions remain hard failures.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
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

DISTILLATION_FIELDS = (
    "teacherCheckpointSHA256",
    "teacherLayers",
    "studentLayers",
    "temperature",
    "distillAlpha",
)


def read_report(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"error: could not read report {path}: {error}") from error
    if not isinstance(document, dict):
        raise SystemExit(f"error: report must contain a JSON object: {path}")
    return document


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_distilled(document: dict[str, Any]) -> bool:
    return (
        document.get("algorithm") == "teacher-student-distillation"
        or isinstance(document.get("distillation"), dict)
    )


def validate_distillation_provenance(document: dict[str, Any]) -> tuple[bool, str]:
    """Return whether a report carries a complete, sane student provenance."""
    if document.get("algorithm") != "teacher-student-distillation":
        return False, "algorithm is not teacher-student-distillation"
    provenance = document.get("distillation")
    if not isinstance(provenance, dict):
        return False, "distillation provenance is missing"
    if any(field not in provenance for field in DISTILLATION_FIELDS):
        return False, "distillation provenance is incomplete"
    teacher_hash = provenance.get("teacherCheckpointSHA256")
    if not isinstance(teacher_hash, str) or len(teacher_hash) != 64:
        return False, "teacher checkpoint hash is invalid"
    if (
        isinstance(provenance.get("teacherLayers"), bool)
        or isinstance(provenance.get("studentLayers"), bool)
        or not isinstance(provenance.get("teacherLayers"), int)
        or not isinstance(provenance.get("studentLayers"), int)
        or provenance["teacherLayers"] <= provenance["studentLayers"]
        or provenance["studentLayers"] <= 0
    ):
        return False, "teacher/student layer provenance is invalid"
    temperature = provenance.get("temperature")
    alpha = provenance.get("distillAlpha")
    if not isinstance(temperature, (int, float)) or temperature < 1:
        return False, "distillation temperature is invalid"
    if not isinstance(alpha, (int, float)) or not 0 <= alpha <= 1:
        return False, "distillation alpha is invalid"
    return True, ""


def report_identity(document: dict[str, Any], report_path: Path | None = None) -> dict[str, Any]:
    """Extract the immutable identity used to bind a gate to one report."""
    identity: dict[str, Any] = {
        "profileID": document.get("profileID"),
        "artifactSHA256": document.get("artifactSHA256"),
    }
    if report_path is not None:
        identity["reportSHA256"] = file_sha256(report_path)
    if is_distilled(document):
        identity["distillation"] = document.get("distillation")
    return identity


def make_gate_report(
    teacher: dict[str, Any],
    student: dict[str, Any],
    comparison: dict[str, Any],
    *,
    teacher_report_path: Path | None = None,
    student_report_path: Path | None = None,
) -> dict[str, Any]:
    """Attach immutable teacher/student provenance to a comparison result."""
    valid, reason = validate_distillation_provenance(student)
    if not valid:
        raise SystemExit(f"error: student report cannot be gated: {reason}")
    teacher_identity = copy.deepcopy(report_identity(teacher, teacher_report_path))
    student_identity = copy.deepcopy(report_identity(student, student_report_path))
    result = dict(comparison)
    result["teacher"] = teacher_identity
    result["student"] = student_identity
    # Flat aliases keep the JSON easy to inspect and make the binding explicit
    # for older tooling that does not understand nested provenance objects.
    result["teacherProfileID"] = teacher_identity.get("profileID")
    result["teacherArtifactSHA256"] = teacher_identity.get("artifactSHA256")
    result["teacherReportSHA256"] = teacher_identity.get("reportSHA256")
    result["studentProfileID"] = student_identity.get("profileID")
    result["studentArtifactSHA256"] = student_identity.get("artifactSHA256")
    result["studentReportSHA256"] = student_identity.get("reportSHA256")
    result["studentDistillation"] = copy.deepcopy(student.get("distillation"))
    return result


def _gate_student_identity(gate: dict[str, Any]) -> dict[str, Any]:
    nested = gate.get("student")
    if isinstance(nested, dict):
        identity = dict(nested)
    else:
        identity = {}
    aliases = {
        "profileID": "studentProfileID",
        "artifactSHA256": "studentArtifactSHA256",
        "reportSHA256": "studentReportSHA256",
    }
    for key, alias in aliases.items():
        if identity.get(key) is None and gate.get(alias) is not None:
            identity[key] = gate[alias]
    if "distillation" not in identity and isinstance(gate.get("studentDistillation"), dict):
        identity["distillation"] = gate["studentDistillation"]
    return identity


def _gate_teacher_identity(gate: dict[str, Any]) -> dict[str, Any]:
    """Read teacher identity from nested provenance or legacy flat aliases."""
    nested = gate.get("teacher")
    if isinstance(nested, dict):
        identity = dict(nested)
    else:
        identity = {}
    aliases = {
        "profileID": "teacherProfileID",
        "artifactSHA256": "teacherArtifactSHA256",
        "reportSHA256": "teacherReportSHA256",
    }
    for key, alias in aliases.items():
        if identity.get(key) is None and gate.get(alias) is not None:
            identity[key] = gate[alias]
    return identity


def gate_matches_student(
    gate: dict[str, Any],
    student: dict[str, Any],
    *,
    student_report_sha256: str | None = None,
    expected_teacher: dict[str, Any] | None = None,
    expected_teacher_report_sha256: str | None = None,
) -> tuple[bool, str]:
    """Validate a gate's pass bit and immutable binding to student and teacher."""
    valid, reason = validate_distillation_provenance(student)
    if not valid:
        return False, reason
    if gate.get("schemaVersion") != 1:
        return False, "unsupported gate schema"
    identity = _gate_student_identity(gate)
    required_identity = ("profileID", "artifactSHA256", "reportSHA256")
    if any(not isinstance(identity.get(field), str) or not identity[field] for field in required_identity):
        return False, "gate student provenance is incomplete"
    if identity["profileID"] != student.get("profileID"):
        return False, "gate student profile does not match report"
    if identity["artifactSHA256"] != student.get("artifactSHA256"):
        return False, "gate student artifact does not match report"
    if student_report_sha256 is not None and identity["reportSHA256"] != student_report_sha256:
        return False, "gate student report hash does not match report"
    if identity.get("distillation") != student.get("distillation"):
        return False, "gate student distillation provenance does not match report"
    teacher = _gate_teacher_identity(gate)
    teacher_fields = ("profileID", "artifactSHA256", "reportSHA256")
    if any(not isinstance(teacher.get(field), str) or not teacher[field] for field in teacher_fields):
        return False, "gate teacher provenance is incomplete"
    if expected_teacher is not None:
        expected = report_identity(expected_teacher)
        expected_report_sha256 = expected_teacher_report_sha256
        if expected_report_sha256 is None:
            raw_path = expected_teacher.get("_reportPath")
            if isinstance(raw_path, (str, Path)):
                report_path = Path(raw_path)
                if report_path.is_file():
                    expected_report_sha256 = file_sha256(report_path)
        if not isinstance(expected_report_sha256, str) or not expected_report_sha256:
            return False, "current teacher report hash is unavailable"
        expected["reportSHA256"] = expected_report_sha256
        if any(not isinstance(expected.get(field), str) or not expected[field] for field in teacher_fields):
            return False, "current teacher provenance is incomplete"
        for field in teacher_fields:
            if teacher[field] != expected[field]:
                return False, f"gate teacher {field} does not match current teacher"
    if gate.get("passed") is not True:
        return False, "distillation gate did not pass"
    return True, ""


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
    teacher_report = arguments.teacher_report.expanduser().resolve()
    student_report = arguments.student_report.expanduser().resolve()
    teacher_document = read_report(teacher_report)
    student_document = read_report(student_report)
    result = compare_reports(
        teacher_document,
        student_document,
        arguments.max_loss,
    )
    result = make_gate_report(
        teacher_document,
        student_document,
        result,
        teacher_report_path=teacher_report,
        student_report_path=student_report,
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
