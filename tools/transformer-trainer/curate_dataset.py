#!/usr/bin/env python3
"""Curate SMS training corpora: merge sources, filter low-quality rows, and audit coverage.

Designed for the mixed corpus this project trains on — synthetic seed rows,
public datasets, and **user-contributed CloudKit samples** (the noisy part).
Filtering happens in two tiers:

1. Rule tier (stdlib only, always on): taxonomy validation, normalization,
   length bounds, junk heuristics, sanitizer-placeholder rehydration, exact +
   near duplicate removal, cross-label conflict removal, language allowlist.
2. Model tier (optional, needs the training venv): embeds every row with the
   SetFit backbone and drops rows whose embedding sits closer to another
   label's centroid than to its own (classic label-noise / mislabeled data).

The audit step verifies the per-label × per-language matrix and enforces that
the project's first-class languages (zh, en, ja) cover every taxonomy label.

Usage:
    uv run curate_dataset.py --inputs a.ndjson b.ndjson --out train.ndjson
    uv run curate_dataset.py --inputs train.ndjson --audit-only --strict-audit
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

CORE_LANGUAGES = ("zh", "en", "ja")
SUPPORTED_LANGUAGES = ("zh", "en", "ja", "es", "pt", "fr", "de", "ru", "ko", "id", "vi", "th")
PLACEHOLDER_PATTERN = re.compile(r"\{\{(PHONE|URL|EMAIL|ADDRESS|CARD|ID|ORDER_ID|AMOUNT|CODE|PLATE|NAME)\}\}")


@dataclass
class Row:
    text: str
    label: str
    source: str
    language: str = "unknown"


@dataclass
class Report:
    inputs: dict[str, int] = field(default_factory=dict)
    holdouts: dict[str, int] = field(default_factory=dict)
    kept: int = 0
    rejected: Counter = field(default_factory=Counter)
    rehydrated_rows: int = 0
    matrix: dict[str, dict[str, int]] = field(default_factory=dict)
    audit_gaps: list[str] = field(default_factory=list)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--inputs", type=Path, nargs="+", required=True, help="NDJSON sources, merged in order")
    parser.add_argument("--out", type=Path, default=None, help="curated NDJSON output")
    parser.add_argument("--rejected", type=Path, default=None, help="rejected rows + reasons (NDJSON)")
    parser.add_argument("--report", type=Path, default=None, help="curation report JSON")
    parser.add_argument("--taxonomy", type=Path, default=None, help="taxonomy.json (default: repo copy)")
    parser.add_argument(
        "--holdout",
        type=Path,
        action="append",
        default=[],
        help="external holdout excluded by exact and digit-normalized signature (repeatable)",
    )
    parser.add_argument("--min-length", type=int, default=8)
    parser.add_argument("--max-length", type=int, default=500)
    parser.add_argument(
        "--languages",
        default="all",
        help=f"comma-separated allowlist out of {','.join(SUPPORTED_LANGUAGES)}; rows in other languages are rejected",
    )
    parser.add_argument(
        "--model-filter",
        choices=["off", "auto", "on"],
        default="off",
        help="embedding-centroid label-noise filter. auto = run when torch is importable",
    )
    parser.add_argument("--model", default="sentence-transformers/distiluse-base-multilingual-cased-v2")
    parser.add_argument(
        "--hard-floor",
        type=float,
        default=-0.15,
        help="margin (own-centroid cosine minus best other-centroid cosine) below which rows are always dropped",
    )
    parser.add_argument(
        "--gray-keep",
        type=float,
        default=0.7,
        help="fraction of gray-zone rows (hard-floor <= margin < 0) kept per label, best margins first",
    )
    parser.add_argument("--min-centroid-rows", type=int, default=8, help="labels with fewer rows are exempt from the model filter")
    parser.add_argument("--audit", action="store_true", help="print the label × language coverage matrix summary")
    parser.add_argument("--audit-only", action="store_true", help="skip filtering/output; only audit the merged inputs")
    parser.add_argument("--strict-audit", action="store_true", help="exit non-zero when core-language coverage gaps exist")
    parser.add_argument("--min-core-rows", type=int, default=10, help="required rows per label for each core language (zh/en/ja)")
    return parser.parse_args()


def locate_repo_root() -> Path:
    directory = Path(__file__).resolve().parent
    while directory != directory.parent:
        if (directory / "packages/taxonomy/taxonomy.json").exists():
            return directory
        directory = directory.parent
    raise SystemExit("error: could not locate repo root containing packages/taxonomy/taxonomy.json")


def load_taxonomy_labels(path: Path) -> set[str]:
    document = json.loads(path.read_text(encoding="utf-8"))
    return {leaf["id"] for group in document["groups"] for leaf in group["leaves"]}


def normalize_language_hint(value: object) -> str:
    raw = str(value or "").strip().lower().replace("_", "-")
    base = raw.split("-", 1)[0]
    aliases = {"cmn": "zh", "eng": "en", "jpn": "ja"}
    normalized = aliases.get(base, base)
    return normalized if normalized in SUPPORTED_LANGUAGES else "unknown"


def load_rows(paths: list[Path], report: Report) -> list[Row]:
    rows: list[Row] = []
    for path in paths:
        if not path.exists():
            print(f"warning: input missing, skipped: {path}")
            report.inputs[str(path)] = 0
            continue
        count = 0
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                record = json.loads(line)
                text, label = str(record.get("text", "")), str(record.get("label", ""))
                if text and label:
                    language = normalize_language_hint(record.get("textLanguage") or record.get("language"))
                    rows.append(Row(text=text, label=label, source=path.name, language=language))
                    count += 1
        report.inputs[str(path)] = count
    return rows


# --- Language detection (script ranges + Latin stopword scoring) ------------

LATIN_MARKERS: dict[str, tuple[set[str], str]] = {
    "es": ({"el", "la", "los", "las", "usted", "para", "código", "cuenta", "gracias", "tu", "pedido"}, "ñ¿¡"),
    "pt": ({"você", "não", "para", "sua", "seu", "obrigado", "conta", "código", "pedido", "entrega"}, "ãõç"),
    "fr": ({"le", "la", "les", "votre", "vous", "est", "pour", "avec", "compte", "colis", "code"}, "àèêç"),
    "de": ({"und", "der", "die", "das", "nicht", "für", "ihr", "ihre", "sie", "bitte", "konto"}, "äöüß"),
    "id": ({"anda", "dan", "untuk", "dengan", "yang", "kode", "paket", "telah", "silakan", "rekening"}, ""),
    "vi": ({"của", "bạn", "và", "cho", "với", "mã", "đơn", "hàng", "tài", "khoản"}, "ơưđạảấềể"),
}


def detect_language(text: str) -> str:
    has_kana = any("぀" <= ch <= "ヿ" for ch in text)
    if has_kana:
        return "ja"
    if any("가" <= ch <= "힯" for ch in text):
        return "ko"
    if any("฀" <= ch <= "๿" for ch in text):
        return "th"
    if any("一" <= ch <= "鿿" or "㐀" <= ch <= "䶿" for ch in text):
        return "zh"
    if any("Ѐ" <= ch <= "ӿ" for ch in text):
        return "ru"

    lowered = text.lower()
    words = set(re.findall(r"[\w']+", lowered, re.UNICODE))
    best_language, best_score = "en", 0
    for language, (stopwords, accents) in LATIN_MARKERS.items():
        score = len(words & stopwords) + sum(2 for ch in accents if ch and ch in lowered)
        if score > best_score:
            best_language, best_score = language, score
    return best_language if best_score >= 2 else "en"


# --- Placeholder rehydration -------------------------------------------------

def stable_rng(seed_text: str) -> "_Rng":
    digest = hashlib.sha256(seed_text.encode("utf-8")).digest()
    return _Rng(int.from_bytes(digest[:8], "big"))


class _Rng:
    def __init__(self, state: int) -> None:
        self.state = state or 0x9E3779B97F4A7C15

    def next_int(self, lower: int, upper: int) -> int:
        self.state = (self.state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        return lower + self.state % (upper - lower + 1)

    def choice(self, values: list[str]) -> str:
        return values[self.next_int(0, len(values) - 1)]


def rehydrate_placeholders(text: str, language: str, rng: "_Rng") -> str:
    """Replaces sanitizer tokens ({{PHONE}}, {{CODE}}, …) with plausible fake
    values so contributed samples match the raw-SMS distribution the filter
    sees at inference time."""
    def value_for(token: str) -> str:
        if token == "PHONE":
            if language == "zh":
                return f"1{rng.next_int(30, 99)}{rng.next_int(10000000, 99999999)}"
            if language == "ja":
                return f"090-{rng.next_int(1000, 9999)}-{rng.next_int(1000, 9999)}"
            return f"+{rng.next_int(1, 81)} {rng.next_int(200, 999)} {rng.next_int(100, 999)} {rng.next_int(1000, 9999)}"
        if token == "URL":
            return f"https://{rng.choice(['t.co', 'bit.ly', 'dwz.cn', 'go.link'])}/{rng.next_int(100000, 999999)}"
        if token == "EMAIL":
            return f"user{rng.next_int(100, 999)}@example.com"
        if token == "ADDRESS":
            if language == "zh":
                return f"幸福路{rng.next_int(1, 199)}号{rng.next_int(1, 30)}栋"
            if language == "ja":
                return f"中央区{rng.next_int(1, 9)}-{rng.next_int(1, 20)}-{rng.next_int(1, 15)}"
            return f"{rng.next_int(1, 999)} Elm Street"
        if token == "CARD":
            return " ".join(str(rng.next_int(1000, 9999)) for _ in range(4))
        if token == "ID":
            if language == "zh":
                body = f"11010{rng.next_int(1, 9)}19{rng.next_int(60, 99)}0{rng.next_int(1, 9)}{rng.next_int(10, 28)}{rng.next_int(100, 999)}"
                weights = (7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2)
                valid_checksum = "10X98765432"[sum(int(digit) * weight for digit, weight in zip(body, weights)) % 11]
                invalid_checksum = "0" if valid_checksum != "0" else "1"
                return body + invalid_checksum
            if language == "ja":
                return "000000000000"
            return "P00000000"
        if token == "ORDER_ID":
            return f"{rng.next_int(100000000, 999999999)}"
        if token == "AMOUNT":
            amount = f"{rng.next_int(1, 999)}.{rng.next_int(0, 99):02d}"
            if language == "zh":
                return f"{amount}元"
            if language == "ja":
                return f"{rng.next_int(100, 99999)}円"
            return f"${amount}"
        if token == "CODE":
            return str(rng.next_int(100000, 999999))
        if token == "PLATE":
            if language == "zh":
                if rng.next_int(0, 4) == 0:
                    return rng.choice([
                        f"{rng.choice(['AB', 'CD', 'EF'])} {rng.next_int(1, 9999)}",
                        str(rng.next_int(1, 9999)),
                    ])
                province = rng.choice(list("京津沪渝冀豫云辽黑湘皖鲁新苏浙赣鄂桂甘晋蒙陕吉闽贵粤青藏川宁琼"))
                letter = rng.choice(list("ABCDEFGHJKLMNPQRSTUVWXYZ"))
                if rng.next_int(0, 3) == 0:
                    suffix = rng.choice(["D", "F"]) + "".join(
                        rng.choice(list("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789")) for _ in range(5)
                    )
                else:
                    suffix = "".join(rng.choice(list("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789")) for _ in range(5))
                return province + letter + suffix
            if language == "ja":
                return (
                    f"{rng.choice(['品川', '練馬', '横浜', '大阪', '神戸'])} "
                    f"{rng.next_int(300, 599)} {rng.choice(list('あいうえかきくけこさすせそたちつてとなにぬねの'))} "
                    f"{rng.next_int(10, 99)}-{rng.next_int(10, 99)}"
                )
            if language == "de":
                return f"{rng.choice(['B', 'M', 'HH'])}-{rng.choice(['AB', 'CD', 'EF'])} {rng.next_int(1, 9999)}"
            if language == "fr":
                return f"{rng.choice(['AB', 'CD', 'EF'])}-{rng.next_int(100, 999)}-{rng.choice(['GH', 'JK', 'LM'])}"
            if language == "es":
                return f"{rng.next_int(1000, 9999)} {rng.choice(['BCD', 'FGH', 'JKL'])}"
            if language == "pt":
                return f"{rng.next_int(10, 99)}-{rng.choice(['AB', 'CD', 'EF'])}-{rng.next_int(10, 99)}"
            return rng.choice([
                f"{rng.choice(['S', 'B', 'M'])}{rng.choice(['AA', 'KT', 'RX'])}{rng.next_int(1000, 9999)}",
                f"{rng.choice(['AB', 'CD', 'EF'])}{rng.next_int(10, 99)} {rng.choice(['CDE', 'FGH', 'JKL'])}",
                f"{rng.choice(['AB', 'CD', 'EF'])} {rng.next_int(1, 9999):04d}",
                f"{rng.choice(['AB', 'ZX', 'KLM'])}-{rng.next_int(1000, 9999)}",
            ])
        if token == "NAME":
            if language == "zh":
                return rng.choice(["李先生", "王女士", "张老师", "陈先生"])
            if language == "ja":
                return rng.choice(["田中様", "佐藤様", "鈴木様"])
            return rng.choice(["John", "Sarah", "Alex", "Maria"])
        return token

    return PLACEHOLDER_PATTERN.sub(lambda match: value_for(match.group(1)), text)


# --- Rule-tier filters --------------------------------------------------------

def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", text)).strip()


def is_placeholder_only(text: str) -> bool:
    residual = PLACEHOLDER_PATTERN.sub("", text)
    return bool(PLACEHOLDER_PATTERN.search(text)) and not any(character.isalnum() for character in residual)


def near_duplicate_signature(text: str) -> str:
    collapsed = re.sub(r"\d+", "0", text.lower())
    collapsed = re.sub(r"[\W_]+", "", collapsed, flags=re.UNICODE)
    return collapsed[:80]


def load_holdout_keys(paths: list[Path], report: Report) -> tuple[set[str], set[str]]:
    exact: set[str] = set()
    signatures: set[str] = set()
    for path in paths:
        if not path.exists():
            raise SystemExit(f"error: holdout missing: {path}")
        count = 0
        with path.open(encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                if not line.strip():
                    continue
                text = normalize(str(json.loads(line).get("text", "")))
                if not text:
                    raise SystemExit(f"error: holdout text missing at {path}:{number}")
                exact.add(text.lower())
                signatures.add(near_duplicate_signature(text))
                count += 1
        report.holdouts[str(path)] = count
    return exact, signatures


def junk_reason(text: str, language: str, min_length: int, max_length: int) -> str | None:
    if len(text) < min_length:
        return "too-short"
    if len(text) > max_length:
        return "too-long"

    informative = sum(1 for ch in text if ch.isalnum())
    if informative / max(len(text), 1) < 0.3:
        return "low-information"

    if len(text) > 20 and len(set(text)) / len(text) < 0.15:
        return "repetitive"

    if language in ("en", "es", "pt", "fr", "de", "id", "vi", "ru"):
        if len(re.findall(r"[\w']+", text, re.UNICODE)) < 2:
            return "too-few-words"

    if is_placeholder_only(text):
        return "placeholder-only"
    return None


def apply_rule_tier(
    rows: list[Row],
    valid_labels: set[str],
    allowed_languages: set[str],
    arguments: argparse.Namespace,
    report: Report,
    rejected_sink: list[dict],
    holdout_exact: set[str] | None = None,
    holdout_signatures: set[str] | None = None,
) -> list[Row]:
    holdout_exact = holdout_exact or set()
    holdout_signatures = holdout_signatures or set()
    kept: list[Row] = []
    seen_exact: set[str] = set()
    seen_signatures: set[str] = set()
    text_to_labels: dict[str, set[str]] = defaultdict(set)

    prepared: list[Row] = []
    for row in rows:
        text = normalize(row.text)
        if not text or row.label not in valid_labels:
            report.rejected["unknown-label" if text else "empty"] += 1
            rejected_sink.append({"text": row.text, "label": row.label, "source": row.source, "reason": "unknown-label"})
            continue
        if is_placeholder_only(text):
            report.rejected["placeholder-only"] += 1
            rejected_sink.append({"text": row.text, "label": row.label, "source": row.source, "reason": "placeholder-only"})
            continue
        row.text = text
        if row.language not in SUPPORTED_LANGUAGES:
            row.language = detect_language(text)
        if PLACEHOLDER_PATTERN.search(text):
            row.text = normalize(rehydrate_placeholders(text, row.language, stable_rng(text)))
            report.rehydrated_rows += 1
        prepared.append(row)
        text_to_labels[row.text.lower()].add(row.label)

    conflicting_texts = {text for text, labels in text_to_labels.items() if len(labels) > 1}

    for row in prepared:
        reason = junk_reason(row.text, row.language, arguments.min_length, arguments.max_length)
        if reason is None and row.language not in allowed_languages:
            reason = f"language:{row.language}"
        if reason is None and row.text.lower() in conflicting_texts:
            reason = "cross-label-conflict"
        signature = near_duplicate_signature(row.text)
        if reason is None and row.text.lower() in holdout_exact:
            reason = "holdout-exact"
        if reason is None and signature in holdout_signatures:
            reason = "holdout-near"
        if reason is None:
            exact_key = f"{row.label}\x1f{row.text}"
            if exact_key in seen_exact:
                reason = "duplicate"
            else:
                seen_exact.add(exact_key)
                label_signature = f"{row.label}\x1f{signature}"
                if label_signature in seen_signatures:
                    reason = "near-duplicate"
                else:
                    seen_signatures.add(label_signature)

        if reason is None:
            kept.append(row)
        else:
            report.rejected[reason.split(":")[0]] += 1
            rejected_sink.append({"text": row.text, "label": row.label, "source": row.source, "language": row.language, "reason": reason})
    return kept


# --- Model-tier filter ---------------------------------------------------------

def apply_model_tier(
    rows: list[Row],
    arguments: argparse.Namespace,
    report: Report,
    rejected_sink: list[dict],
) -> list[Row]:
    try:
        import numpy as np
        import torch
        from sentence_transformers import SentenceTransformer
    except ImportError:
        if arguments.model_filter == "on":
            raise SystemExit("error: --model-filter on requires torch + sentence-transformers (run inside `uv run`)")
        print("note: torch unavailable, skipping model-tier filter")
        return rows

    device = "cuda" if torch.cuda.is_available() else (
        "mps" if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available() else "cpu"
    )
    print(f"model-tier filter: embedding {len(rows)} rows with {arguments.model} on {device}")
    model = SentenceTransformer(arguments.model, device=device)
    embeddings = model.encode(
        [row.text for row in rows],
        batch_size=128,
        normalize_embeddings=True,
        show_progress_bar=False,
    )
    embeddings = np.asarray(embeddings)

    by_label: dict[str, list[int]] = defaultdict(list)
    for index, row in enumerate(rows):
        by_label[row.label].append(index)

    centroids: dict[str, "np.ndarray"] = {}
    for label, indices in by_label.items():
        if len(indices) >= arguments.min_centroid_rows:
            centroid = embeddings[indices].mean(axis=0)
            centroids[label] = centroid / (np.linalg.norm(centroid) + 1e-12)

    if len(centroids) < 2:
        print("note: not enough labels with centroids, skipping model-tier filter")
        return rows

    labels = sorted(centroids)
    centroid_matrix = np.stack([centroids[label] for label in labels])
    label_index = {label: position for position, label in enumerate(labels)}

    similarities = embeddings @ centroid_matrix.T

    # Three-band policy instead of a single threshold. Hard mislabels
    # (margin < hard floor) always drop; the ambiguous gray zone keeps only
    # the best `--gray-keep` fraction per label so genuine corrections and
    # boundary examples survive while the noise rate stays bounded; clear
    # agreements always stay.
    margins: list[float | None] = []
    for index, row in enumerate(rows):
        position = label_index.get(row.label)
        if position is None:
            margins.append(None)
            continue
        own = similarities[index, position]
        others = np.delete(similarities[index], position)
        margins.append(float(own - others.max()))

    gray_by_label: dict[str, list[int]] = defaultdict(list)
    for index, margin in enumerate(margins):
        if margin is not None and arguments.hard_floor <= margin < 0:
            gray_by_label[rows[index].label].append(index)

    gray_dropped: set[int] = set()
    for label, indices in gray_by_label.items():
        indices.sort(key=lambda idx: margins[idx], reverse=True)
        keep_count = int(len(indices) * arguments.gray_keep + 0.9999)
        gray_dropped.update(indices[keep_count:])

    kept: list[Row] = []
    for index, row in enumerate(rows):
        margin = margins[index]
        if margin is None or margin >= 0:
            kept.append(row)
            continue
        if margin < arguments.hard_floor:
            reason = "label-noise"
        elif index in gray_dropped:
            reason = "gray-zone-drop"
        else:
            kept.append(row)
            continue
        report.rejected[reason] += 1
        rejected_sink.append({
            "text": row.text, "label": row.label, "source": row.source,
            "language": row.language, "reason": reason, "margin": round(margin, 4),
        })
    return kept


# --- Audit ---------------------------------------------------------------------

def build_matrix(rows: list[Row], valid_labels: set[str], report: Report) -> None:
    matrix: dict[str, dict[str, int]] = {label: defaultdict(int) for label in sorted(valid_labels)}
    for row in rows:
        matrix[row.label][row.language] += 1
    report.matrix = {label: dict(counts) for label, counts in matrix.items()}


def audit_core_coverage(report: Report, min_core_rows: int) -> None:
    for label, counts in report.matrix.items():
        for language in CORE_LANGUAGES:
            count = counts.get(language, 0)
            if count < min_core_rows:
                report.audit_gaps.append(f"{label}/{language}: {count} < {min_core_rows}")


def print_audit(report: Report, min_core_rows: int) -> None:
    language_totals: Counter = Counter()
    for counts in report.matrix.values():
        language_totals.update(counts)
    print("language totals:", dict(sorted(language_totals.items(), key=lambda item: -item[1])))
    if report.audit_gaps:
        print(f"core-language coverage gaps (min {min_core_rows} rows per label for {'/'.join(CORE_LANGUAGES)}):")
        for gap in report.audit_gaps:
            print(f"  {gap}")
    else:
        print(f"core-language coverage OK: every label has >= {min_core_rows} rows in each of {'/'.join(CORE_LANGUAGES)}")


def main() -> None:
    arguments = parse_arguments()
    repo_root = locate_repo_root()
    taxonomy_path = arguments.taxonomy or repo_root / "packages/taxonomy/taxonomy.json"
    valid_labels = load_taxonomy_labels(taxonomy_path)

    if arguments.languages.strip().lower() == "all":
        allowed_languages = set(SUPPORTED_LANGUAGES)
    else:
        allowed_languages = {token.strip().lower() for token in arguments.languages.split(",") if token.strip()}
        unknown = allowed_languages - set(SUPPORTED_LANGUAGES)
        if unknown:
            raise SystemExit(f"error: unsupported languages: {', '.join(sorted(unknown))}")

    report = Report()
    rejected_sink: list[dict] = []
    rows = load_rows(list(arguments.inputs), report)
    holdout_exact, holdout_signatures = load_holdout_keys(
        [path.expanduser().resolve() for path in arguments.holdout],
        report,
    )
    print(f"loaded {len(rows)} rows from {len(arguments.inputs)} inputs")

    if arguments.audit_only:
        for row in rows:
            row.text = normalize(row.text)
            if row.language not in SUPPORTED_LANGUAGES:
                row.language = detect_language(row.text)
        rows = [row for row in rows if row.label in valid_labels]
        build_matrix(rows, valid_labels, report)
        audit_core_coverage(report, arguments.min_core_rows)
        print_audit(report, arguments.min_core_rows)
        if arguments.report:
            arguments.report.parent.mkdir(parents=True, exist_ok=True)
            arguments.report.write_text(json.dumps(report.__dict__, ensure_ascii=False, indent=2, default=dict) + "\n", encoding="utf-8")
        sys.exit(2 if arguments.strict_audit and report.audit_gaps else 0)

    if not arguments.out:
        raise SystemExit("error: --out is required unless --audit-only")

    rows = apply_rule_tier(
        rows,
        valid_labels,
        allowed_languages,
        arguments,
        report,
        rejected_sink,
        holdout_exact,
        holdout_signatures,
    )
    if arguments.model_filter != "off":
        rows = apply_model_tier(rows, arguments, report, rejected_sink)

    report.kept = len(rows)
    build_matrix(rows, valid_labels, report)
    audit_core_coverage(report, arguments.min_core_rows)

    arguments.out.parent.mkdir(parents=True, exist_ok=True)
    payload = "\n".join(json.dumps({"text": row.text, "label": row.label}, ensure_ascii=False) for row in rows)
    arguments.out.write_text(payload + "\n" if payload else "", encoding="utf-8")

    if arguments.rejected:
        arguments.rejected.parent.mkdir(parents=True, exist_ok=True)
        rejected_payload = "\n".join(json.dumps(item, ensure_ascii=False) for item in rejected_sink)
        arguments.rejected.write_text(rejected_payload + "\n" if rejected_payload else "", encoding="utf-8")

    if arguments.report:
        arguments.report.parent.mkdir(parents=True, exist_ok=True)
        arguments.report.write_text(json.dumps(report.__dict__, ensure_ascii=False, indent=2, default=dict) + "\n", encoding="utf-8")

    print(f"kept {report.kept} rows -> {arguments.out}")
    print(f"rejected {sum(report.rejected.values())} rows: {dict(report.rejected)}")
    if report.rehydrated_rows:
        print(f"rehydrated sanitizer placeholders in {report.rehydrated_rows} rows")
    if arguments.audit or arguments.strict_audit:
        print_audit(report, arguments.min_core_rows)
    if arguments.strict_audit and report.audit_gaps:
        sys.exit(2)


if __name__ == "__main__":
    main()
