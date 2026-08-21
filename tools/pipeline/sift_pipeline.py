#!/usr/bin/env python3
"""Sift end-to-end training pipeline.

One command drives the whole flow — dataset download/refresh, CloudKit sample
export, quality curation + coverage audit, both model trainings (with optional
checkpoint resume), and Core ML installation into the iOS app:

    python3 tools/pipeline/sift_pipeline.py all --install-ios

Stages (run individually with `--only`, or drop some with `--skip`):

  fetch-public       multilingual synthetic seed rows + public SMS datasets
                     (swift run SiftAppleTrainer --build-public-corpus)
  fetch-remote       opt-in user samples from the CloudKit public database
                     (pnpm export:training; skipped politely without creds)
  curate             merge + quality-filter + placeholder rehydration +
                     dedupe + optional embedding label-noise filter
                     (uv run curate_dataset.py), then coverage audit
  augment            add versioned, leak-free semantic and boundary variants
                     with per-label diversity caps
  prune              remove high-similarity same-label/language repetitions
                     while preserving reviewed boundaries and provenance
  train-classic      Create ML model (swift run SiftAppleTrainer --input …)
  train-transformer  frozen FP32 mmBERT Core ML baseline
  distill-transformer  release-qualified 12-layer student from the teacher checkpoint
  quantize-transformer  build every configured W8/W4 candidate and run the
                     external holdout/action evaluation
  select-transformer  select only a candidate with device evidence and all
                     quality gates; writes selected-candidate.json
  finetune           incremental update: resume the latest transformer
                     checkpoint on the freshly curated corpus with a low
                     learning rate instead of retraining from scratch

Everything lands under build/pipeline/. The pipeline is deterministic given
the same inputs and seeds, and each stage validates its own inputs so a
failed stage can be re-run in isolation.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

STAGES = ["fetch-public", "fetch-remote", "curate", "augment", "prune", "train-classic", "train-transformer", "distill-transformer", "quantize-transformer"]

REPO_ROOT = Path(__file__).resolve().parents[2]
APPLE_TRAINER = REPO_ROOT / "tools/apple-trainer"
TRANSFORMER_TRAINER = REPO_ROOT / "tools/transformer-trainer"
PIPELINE_DIR = REPO_ROOT / "build/pipeline"

PUBLIC_CORPUS = PIPELINE_DIR / "public-corpus.ndjson"
REMOTE_CORPUS = PIPELINE_DIR / "remote-training.ndjson"
TRAIN_SET = PIPELINE_DIR / "train.ndjson"
UNPRUNED_TRAIN_SET = PIPELINE_DIR / "train.augmented.ndjson"
CURATED_SET = PIPELINE_DIR / "train.curated.ndjson"
REJECTED_SET = PIPELINE_DIR / "rejected.ndjson"
CURATION_REPORT = PIPELINE_DIR / "curation-report.json"
AUGMENTATION_REPORT = PIPELINE_DIR / "augmentation-report.json"
PRUNING_REPORT = PIPELINE_DIR / "pruning-report.json"
PRUNING_REJECTED_SET = PIPELINE_DIR / "pruning-rejected.ndjson"
CONVERSATION_TRAIN_SET = PIPELINE_DIR / "conversation-training.ndjson"
CLASSIC_OUT = PIPELINE_DIR / "apple-model"
TRANSFORMER_OUT = PIPELINE_DIR / "transformer-model"
PROMOTION_TEST_SET = APPLE_TRAINER / "Evaluation" / "promotion-regressions.ndjson"
CLASSIFICATION_TEST_SET = APPLE_TRAINER / "Evaluation" / "classification-regressions.ndjson"
BILLING_CARD_TEST_SET = APPLE_TRAINER / "Evaluation" / "billing-card-regressions.ndjson"
CONVERSATION_TEST_SET = TRANSFORMER_TRAINER / "Evaluation" / "conversation-regressions.ndjson"
FEIZHU_TEST_SET = APPLE_TRAINER / "Evaluation" / "feizhu-boundary.ndjson"
CRUISE_TICKETING_TEST_SET = APPLE_TRAINER / "Evaluation" / "cruise-ticketing-boundary.ndjson"
GENERALIZATION_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-blind-v1.ndjson"
GENERALIZATION_ACCEPTANCE_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v1.ndjson"
GENERALIZATION_ACCEPTANCE_V2_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v2.ndjson"
GENERALIZATION_ACCEPTANCE_V3_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v3.ndjson"
GENERALIZATION_ACCEPTANCE_V4_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v4.ndjson"
GENERALIZATION_ACCEPTANCE_V5_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v5.ndjson"
GENERALIZATION_ACCEPTANCE_V6_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v6.ndjson"
GENERALIZATION_ACCEPTANCE_V7_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v7.ndjson"
GENERALIZATION_ACCEPTANCE_V8_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v8.ndjson"
GENERALIZATION_ACCEPTANCE_V9_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v9.ndjson"
GENERALIZATION_ACCEPTANCE_V10_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v10.ndjson"
GENERALIZATION_ACCEPTANCE_V11_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v11.ndjson"
GENERALIZATION_ACCEPTANCE_V12_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v12.ndjson"
GENERALIZATION_ACCEPTANCE_V13_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v13.ndjson"
GENERALIZATION_ACCEPTANCE_V14_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v14.ndjson"
GENERALIZATION_ACCEPTANCE_V15_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v15.ndjson"
GENERALIZATION_ACCEPTANCE_V16_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v16.ndjson"
GENERALIZATION_ACCEPTANCE_V17_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v17.ndjson"
GENERALIZATION_ACCEPTANCE_V18_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v18.ndjson"
GENERALIZATION_ACCEPTANCE_V19_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v19.ndjson"
GENERALIZATION_ACCEPTANCE_V20_TEST_SET = APPLE_TRAINER / "Evaluation" / "generalization-acceptance-v20.ndjson"
TRAINING_SUPPLEMENTS = (
    APPLE_TRAINER / "Training" / "feizhu-boundary-supplement.ndjson",
    APPLE_TRAINER / "Training" / "feizhu-promotion-supplement.ndjson",
    APPLE_TRAINER / "Training" / "cruise-ticketing-supplement.ndjson",
    APPLE_TRAINER / "Training" / "cloud-service-expiry-supplement.ndjson",
    APPLE_TRAINER / "Training" / "model-generalization-v27-supplement.ndjson",
    APPLE_TRAINER / "Training" / "acceptance-v1-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "advance-fee-boundary-v2-supplement.ndjson",
    APPLE_TRAINER / "Training" / "cloud-expiry-boundary-v2-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v2-v3-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v4-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v4-targeted-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v5-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v6-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v7-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v8-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v8-r2-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v9-regression-variants.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v10-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v11-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v12-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v13-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v14-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "generalization-v16-regression-supplement.ndjson",
    APPLE_TRAINER / "Training" / "travel-credential-boundary-v17-supplement.ndjson",
    APPLE_TRAINER / "Training" / "travel-trust-boundary-v18-supplement.ndjson",
    APPLE_TRAINER / "Training" / "operational-confidence-boundary-v20-supplement.ndjson",
)
BOUNDARY_AUGMENTATION_CONFIGS = (
    APPLE_TRAINER / "Training" / "generalization-v48-hard-boundaries.json",
    APPLE_TRAINER / "Training" / "generalization-v49-hard-boundaries.json",
    APPLE_TRAINER / "Training" / "generalization-v50-digital-fulfillment.json",
)


def holdout_test_sets() -> tuple[Path, ...]:
    return (
        CLASSIFICATION_TEST_SET,
        PROMOTION_TEST_SET,
        BILLING_CARD_TEST_SET,
        CONVERSATION_TEST_SET,
        FEIZHU_TEST_SET,
        CRUISE_TICKETING_TEST_SET,
        GENERALIZATION_TEST_SET,
        GENERALIZATION_ACCEPTANCE_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V2_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V3_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V4_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V5_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V6_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V7_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V8_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V9_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V10_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V11_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V12_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V13_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V14_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V15_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V16_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V17_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V18_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V19_TEST_SET,
        GENERALIZATION_ACCEPTANCE_V20_TEST_SET,
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", nargs="?", default="all", choices=["all", *STAGES, "select-transformer", "finetune"], help="stage to run (default all)")
    parser.add_argument("--skip", default="", help=f"comma-separated stages to skip out of: {','.join(STAGES)}")
    parser.add_argument("--only", default="", help="comma-separated stages to run (overrides command/--skip)")

    corpus = parser.add_argument_group("dataset")
    corpus.add_argument("--per-label", type=int, default=80, help="Chinese synthetic rows per label")
    corpus.add_argument("--core-per-label", type=int, default=60, help="en/ja synthetic rows per label")
    corpus.add_argument("--intl-per-label", type=int, default=16, help="rows per covered label for other languages")
    corpus.add_argument("--public-per-label", type=int, default=500, help="max public-dataset rows per label")
    corpus.add_argument(
        "--public-source-policy",
        choices=["curated", "all"],
        default="curated",
        help="curated keeps sources with explicit reuse terms; all opts into undeclared-license sources",
    )
    corpus.add_argument("--seed-languages", default="all", help="seed languages passed to SiftAppleTrainer")
    corpus.add_argument("--extra-input", type=Path, action="append", default=[], help="additional NDJSON merged during curation (repeatable)")

    remote = parser.add_argument_group("cloudkit")
    remote.add_argument("--cloudkit-env", choices=["development", "production"], default="production")
    remote.add_argument("--require-remote", action="store_true", help="fail instead of skipping when CloudKit creds are missing")

    quality = parser.add_argument_group("quality")
    quality.add_argument("--model-filter", choices=["off", "auto", "on"], default="auto", help="embedding label-noise filter during curation")
    quality.add_argument("--hard-floor", type=float, default=-0.15, help="margin below which rows always drop")
    quality.add_argument("--gray-keep", type=float, default=0.7, help="fraction of gray-zone rows kept per label")
    quality.add_argument("--min-core-rows", type=int, default=10, help="audit floor per label for zh/en/ja")
    quality.add_argument("--strict-audit", action="store_true", help="fail the pipeline on core-language coverage gaps")
    quality.add_argument("--remote-disagreement-keep", type=float, default=0.5, help="keep fraction for high-confidence CloudKit/model disagreements")
    quality.add_argument(
        "--max-rows-per-source-label-language",
        type=int,
        default=500,
        help="deterministic source diversity cap applied before model filtering (0 disables)",
    )
    quality.add_argument(
        "--augmentation-config",
        type=Path,
        default=TRANSFORMER_TRAINER / "generalization-augmentation.json",
    )
    quality.add_argument(
        "--boundary-config",
        type=Path,
        action="append",
        default=list(BOUNDARY_AUGMENTATION_CONFIGS),
        help="versioned JSON boundary configs merged during augmentation (repeatable)",
    )
    quality.add_argument("--max-augmented-per-label", type=int, default=120)
    quality.add_argument("--max-variants-per-row", type=int, default=1)
    quality.add_argument(
        "--semantic-prune-threshold",
        type=float,
        default=0.96,
        help="same-label/language cosine threshold for removing semantic repetitions",
    )
    quality.add_argument(
        "--cross-label-similarity-threshold",
        type=float,
        default=0.96,
        help="same-language cross-label cosine threshold that fails pruning",
    )
    quality.add_argument(
        "--min-rows-per-label-language",
        type=int,
        default=20,
        help="minimum rows preserved in each label/language bucket during pruning",
    )

    training = parser.add_argument_group("training")
    training.add_argument("--version-classic", default="maxent-generalization-v50-seed29-r32")
    training.add_argument(
        "--algorithm-classic",
        choices=["maxent", "bert", "auto"],
        default="maxent",
        help="Create ML classic algorithm; maxent is the current validated default",
    )
    training.add_argument("--split-seed-classic", type=int, default=42, help="classic model holdout split seed")
    training.add_argument("--version-transformer", default="signal-v4-generalization-v50-r32-distilled-12l")
    training.add_argument("--model-abi", default="sift-signal-v1")
    training.add_argument("--backbone", default="jhu-clsp/mmBERT-small", help="transformer backbone")
    training.add_argument("--device", choices=["auto", "cpu", "cuda", "mps"], default="auto")
    training.add_argument("--quantize", choices=["fp16", "int8"], default="int8")
    training.add_argument("--quantization-profiles", type=Path, default=TRANSFORMER_TRAINER / "quantization-profiles.json")
    training.add_argument("--release-sequence", type=int, default=4)
    training.add_argument("--minimum-app-build", type=int, default=19)
    training.add_argument("--maximum-app-build", type=int, default=2_147_483_647)
    training.add_argument("--calibration-limit", type=int, default=256)
    training.add_argument(
        "--qat-model",
        action="append",
        default=[],
        metavar="PROFILE_ID=MLPACKAGE",
        help="QAT FP16 export for a W4 fallback profile; repeat for multiple profiles",
    )
    training.add_argument(
        "--truncate-layers",
        type=int,
        default=0,
        help="encoder layers kept for experiments; 0 preserves the full model",
    )
    training.add_argument(
        "--distill-teacher-checkpoint",
        type=Path,
        default=None,
        help="teacher checkpoint for distill-transformer; defaults to transformer-model/teacher-checkpoint",
    )
    training.add_argument("--distill-temperature", type=float, default=2.0)
    training.add_argument("--distill-alpha", type=float, default=0.7)
    training.add_argument(
        "--distillation-gate",
        type=Path,
        action="append",
        default=[],
        help=(
            "gate JSON produced by check_distillation_gate.py for select-transformer; "
            "repeat for multiple candidates (auto-discovered beside quantization reports when omitted)"
        ),
    )
    training.add_argument(
        "--max-sequence-length",
        type=int,
        default=96,
        help="fixed token length exported to Core ML",
    )
    training.add_argument("--resume-from", type=Path, default=None, help="mmBERT checkpoint dir (e.g. build/pipeline/transformer-model/checkpoint)")
    training.add_argument("--learning-rate", type=float, default=None, help="supervised fine-tuning LR; finetune defaults to 1e-5")
    training.add_argument("--num-epochs", type=int, default=3)
    training.add_argument("--batch-size", type=int, default=8)
    training.add_argument("--warmup-ratio", type=float, default=0.06)
    training.add_argument(
        "--train-new-label-rows-only",
        action="store_true",
        help="on checkpoint label expansion, update only newly added classifier rows",
    )
    training.add_argument(
        "--train-label-rows",
        default="",
        help="comma-separated classifier labels to update while preserving all other output rows",
    )
    training.add_argument(
        "--boundary-loss-weight",
        type=float,
        default=1.0,
        help="loss multiplier for reviewed boundary rows without duplicating corpus samples",
    )
    training.add_argument(
        "--selected-label-loss-weight",
        type=float,
        default=1.0,
        help="positive-row loss multiplier for labels selected by --train-label-rows",
    )
    training.add_argument("--install-ios", action="store_true", help="install trained artifacts into apps/ios/GeneratedModels")

    raw_arguments = sys.argv[1:]
    if raw_arguments[:1] == ["--"]:
        raw_arguments = raw_arguments[1:]
    return parser.parse_args(raw_arguments)


def run(command: list[str], cwd: Path, extra_env: dict[str, str] | None = None) -> None:
    print(f"  $ {' '.join(str(part) for part in command)}  (cwd={cwd.relative_to(REPO_ROOT)})")
    env = {**os.environ, **(extra_env or {})}
    result = subprocess.run(command, cwd=cwd, env=env)
    if result.returncode != 0:
        raise SystemExit(f"error: stage command failed with exit code {result.returncode}")


def require_tool(name: str, hint: str) -> None:
    if shutil.which(name) is None:
        raise SystemExit(f"error: `{name}` is required for this stage. {hint}")


def normalized_text(text: str) -> str:
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", text)).strip()


def near_duplicate_signature(text: str) -> str:
    collapsed = re.sub(r"\d+", "0", normalized_text(text).lower())
    return re.sub(r"[\W_]+", "", collapsed, flags=re.UNICODE)[:80]


def load_texts(path: Path) -> list[str]:
    texts: list[str] = []
    with path.open(encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            text = normalized_text(str(json.loads(line).get("text", "")))
            if not text:
                raise SystemExit(f"error: missing text at {path}:{number}")
            texts.append(text)
    return texts


def require_holdout_isolation(path: Path) -> None:
    holdout_texts = [
        text
        for holdout_path in holdout_test_sets()
        for text in load_texts(holdout_path)
    ]
    holdout_exact = {text.lower() for text in holdout_texts}
    holdout_near = {near_duplicate_signature(text) for text in holdout_texts}
    exact_collisions = 0
    near_collisions = 0
    for text in load_texts(path):
        if text.lower() in holdout_exact:
            exact_collisions += 1
        elif near_duplicate_signature(text) in holdout_near:
            near_collisions += 1
    if exact_collisions or near_collisions:
        raise SystemExit(
            "error: refusing to train on holdout-contaminated corpus: "
            f"{exact_collisions} exact and {near_collisions} near collisions; rerun the curate stage"
        )


def stage_fetch_public(arguments: argparse.Namespace) -> None:
    require_tool("swift", "Install Xcode command line tools.")
    run(
        [
            "swift", "run", "-q", "SiftAppleTrainer",
            "--build-public-corpus", str(PUBLIC_CORPUS),
            "--per-label", str(arguments.per_label),
            "--core-per-label", str(arguments.core_per_label),
            "--intl-per-label", str(arguments.intl_per_label),
            "--public-per-label", str(arguments.public_per_label),
            "--public-source-policy", arguments.public_source_policy,
            "--languages", arguments.seed_languages,
        ],
        cwd=APPLE_TRAINER,
    )


def stage_fetch_remote(arguments: argparse.Namespace) -> None:
    if not os.environ.get("CLOUDKIT_KEY_ID") or not os.environ.get("CLOUDKIT_PRIVATE_KEY"):
        message = "CloudKit credentials missing (CLOUDKIT_KEY_ID / CLOUDKIT_PRIVATE_KEY)"
        if arguments.require_remote:
            raise SystemExit(f"error: {message}")
        if REMOTE_CORPUS.exists():
            print(f"  preserving existing CloudKit export: {REMOTE_CORPUS.relative_to(REPO_ROOT)} ({message})")
        else:
            print(f"  skipping remote export: {message}")
        return
    require_tool("pnpm", "Install pnpm (https://pnpm.io).")
    run(
        [
            "pnpm", "--filter", "@sift/cloudkit-tools", "export", "--",
            "--env", arguments.cloudkit_env,
            "--out", str(REMOTE_CORPUS),
        ],
        cwd=REPO_ROOT,
    )


def stage_curate(arguments: argparse.Namespace) -> None:
    run(
        [
            sys.executable,
            str(TRANSFORMER_TRAINER / "generate_conversation_corpus.py"),
            "--out", str(CONVERSATION_TRAIN_SET),
            "--holdout", str(CONVERSATION_TEST_SET),
            "--per-language", "220",
            "--seed", "42",
        ],
        cwd=REPO_ROOT,
    )
    inputs = [PUBLIC_CORPUS, CONVERSATION_TRAIN_SET, *TRAINING_SUPPLEMENTS]
    if REMOTE_CORPUS.exists():
        inputs.append(REMOTE_CORPUS)
    inputs.extend(path.expanduser().resolve() for path in arguments.extra_input)
    existing = [path for path in inputs if path.exists()]
    if not existing:
        raise SystemExit("error: no curation inputs exist; run fetch-public first")

    # The rule tier is stdlib-only; the ML venv (uv) is needed only when the
    # embedding label-noise filter may run.
    if arguments.model_filter == "off":
        runner = [sys.executable]
    else:
        require_tool("uv", "Install uv (https://docs.astral.sh/uv), or pass --model-filter off.")
        runner = ["uv", "run"]

    command = [
        *runner, "curate_dataset.py",
        "--inputs", *[str(path) for path in existing],
        "--out", str(CURATED_SET),
        "--rejected", str(REJECTED_SET),
        "--report", str(CURATION_REPORT),
        *[
            argument
            for holdout_path in holdout_test_sets()
            for argument in ("--holdout", str(holdout_path))
        ],
        "--model-filter", arguments.model_filter,
        "--hard-floor", str(arguments.hard_floor),
        "--gray-keep", str(arguments.gray_keep),
        "--min-core-rows", str(arguments.min_core_rows),
        "--remote-disagreement-keep", str(arguments.remote_disagreement_keep),
        "--max-rows-per-source-label-language", str(arguments.max_rows_per_source_label_language),
        "--audit",
    ]
    if arguments.strict_audit:
        command.append("--strict-audit")
    run(command, cwd=TRANSFORMER_TRAINER)


def stage_augment(arguments: argparse.Namespace) -> None:
    require_tool("python3", "Install Python 3.10+.")
    if not CURATED_SET.exists():
        raise SystemExit("error: run curate before augment")
    run(
        [
            "python3", str(TRANSFORMER_TRAINER / "augment_dataset.py"),
            "--input", str(CURATED_SET),
            "--config", str(arguments.augmentation_config),
            *[
                argument
                for boundary_config in arguments.boundary_config
                for argument in ("--boundary-config", str(boundary_config))
            ],
            *[
                argument
                for holdout_path in holdout_test_sets()
                for argument in ("--holdout", str(holdout_path))
            ],
            "--taxonomy", str(REPO_ROOT / "packages/taxonomy/taxonomy.json"),
            "--out", str(UNPRUNED_TRAIN_SET),
            "--report", str(AUGMENTATION_REPORT),
            "--max-augmented-per-label", str(arguments.max_augmented_per_label),
            "--max-variants-per-row", str(arguments.max_variants_per_row),
        ],
        cwd=REPO_ROOT,
    )


def stage_prune(arguments: argparse.Namespace) -> None:
    require_tool("uv", "Install uv (https://docs.astral.sh/uv).")
    if not UNPRUNED_TRAIN_SET.exists():
        raise SystemExit(f"error: {UNPRUNED_TRAIN_SET} missing; run the augment stage first")
    run(
        [
            "uv", "run", "prune_dataset.py",
            "--input", str(UNPRUNED_TRAIN_SET),
            "--out", str(TRAIN_SET),
            "--rejected", str(PRUNING_REJECTED_SET),
            "--report", str(PRUNING_REPORT),
            "--similarity-threshold", str(arguments.semantic_prune_threshold),
            "--cross-label-threshold", str(arguments.cross_label_similarity_threshold),
            "--min-rows-per-label-language", str(arguments.min_rows_per_label_language),
        ],
        cwd=TRANSFORMER_TRAINER,
    )
    require_holdout_isolation(TRAIN_SET)


def stage_train_classic(arguments: argparse.Namespace) -> None:
    require_tool("swift", "Install Xcode command line tools.")
    if not TRAIN_SET.exists():
        raise SystemExit(f"error: {TRAIN_SET} missing; run the augment and prune stages first")
    require_holdout_isolation(TRAIN_SET)
    command = [
        "swift", "run", "-q", "SiftAppleTrainer",
        "--input", str(TRAIN_SET),
        "--out", str(CLASSIC_OUT),
        "--algorithm", arguments.algorithm_classic,
        "--split-seed", str(arguments.split_seed_classic),
        "--version", arguments.version_classic,
        "--test-input", str(PROMOTION_TEST_SET),
    ]
    run(command, cwd=APPLE_TRAINER)
    run(
        [
            "swift", "run", "--package-path", str(REPO_ROOT / "apps/ios"),
            "ClassicMessageFilterArtifactTests",
            "--model", str(CLASSIC_OUT / "SiftSMSClassifier.mlmodel"),
            "--fixed", str(CLASSIFICATION_TEST_SET),
            "--promotion", str(PROMOTION_TEST_SET),
            "--billing", str(BILLING_CARD_TEST_SET),
            "--conversation", str(CONVERSATION_TEST_SET),
            "--output", str(CLASSIC_OUT / "classic-message-filter-report.json"),
        ],
        cwd=REPO_ROOT,
    )
    # Reuse the strictest artifact-suite slots to require every reviewed
    # boundary row to keep both its raw label and production MessageFilter
    # action. Duplicating each set here also exercises the unsafe-junk gate.
    run(
        [
            "swift", "run", "--package-path", str(REPO_ROOT / "apps/ios"),
            "ClassicMessageFilterArtifactTests",
            "--model", str(CLASSIC_OUT / "SiftSMSClassifier.mlmodel"),
            "--fixed", str(FEIZHU_TEST_SET),
            "--promotion", str(FEIZHU_TEST_SET),
            "--billing", str(CRUISE_TICKETING_TEST_SET),
            "--conversation", str(CRUISE_TICKETING_TEST_SET),
            "--output", str(CLASSIC_OUT / "boundary-message-filter-report.json"),
        ],
        cwd=REPO_ROOT,
    )
    run(
        [
            "swift", str(APPLE_TRAINER / "Scripts" / "evaluate_classic_models.swift"),
            "--require-perfect",
            "--test", f"feizhu={FEIZHU_TEST_SET}",
            "--test", f"cruise={CRUISE_TICKETING_TEST_SET}",
            str(CLASSIC_OUT / "SiftSMSClassifier.mlmodel"),
        ],
        cwd=APPLE_TRAINER,
    )
    if arguments.install_ios:
        destination = REPO_ROOT / "apps/ios/GeneratedModels"
        destination.mkdir(parents=True, exist_ok=True)
        for name in ("SiftSMSClassifier.mlmodel", "SiftSMSClassifier.manifest.json"):
            shutil.copy2(CLASSIC_OUT / name, destination / name)
        print(f"  installed classic model: {destination.relative_to(REPO_ROOT)}")


def stage_train_transformer(arguments: argparse.Namespace, finetune: bool = False) -> None:
    require_tool("uv", "Install uv (https://docs.astral.sh/uv).")
    if not TRAIN_SET.exists():
        raise SystemExit(f"error: {TRAIN_SET} missing; run the augment and prune stages first")
    require_holdout_isolation(TRAIN_SET)

    resume_from = arguments.resume_from
    learning_rate = arguments.learning_rate
    if finetune:
        resume_from = resume_from or (TRANSFORMER_OUT / "checkpoint")
        if not resume_from.exists():
            raise SystemExit(
                f"error: no checkpoint to finetune from ({resume_from}); "
                "run train-transformer once or pass --resume-from"
            )
        learning_rate = learning_rate if learning_rate is not None else 1e-5
    learning_rate = learning_rate if learning_rate is not None else 2e-5

    command = [
        "uv", "run", "train_mmbert.py",
        "--input", str(TRAIN_SET),
        "--out", str(TRANSFORMER_OUT),
        "--version", arguments.version_transformer,
        "--model-abi", arguments.model_abi,
        "--backbone", arguments.backbone,
        "--device", arguments.device,
        "--release-sequence", str(arguments.release_sequence),
        "--minimum-app-build", str(arguments.minimum_app_build),
        "--maximum-app-build", str(arguments.maximum_app_build),
        "--quantize", "fp16",
        "--learning-rate", str(learning_rate),
        "--num-epochs", str(arguments.num_epochs),
        "--batch-size", str(arguments.batch_size),
        "--warmup-ratio", str(arguments.warmup_ratio),
        "--boundary-loss-weight", str(arguments.boundary_loss_weight),
        "--selected-label-loss-weight", str(arguments.selected_label_loss_weight),
        "--max-length", str(arguments.max_sequence_length),
        "--test-input", str(PROMOTION_TEST_SET),
    ]
    if arguments.truncate_layers > 0:
        command.extend(["--truncate-layers", str(arguments.truncate_layers)])
    if arguments.train_new_label_rows_only:
        command.append("--train-new-label-rows-only")
    if arguments.train_label_rows:
        command.extend(["--train-label-rows", arguments.train_label_rows])
    if resume_from is not None:
        command.extend(["--resume-from", str(resume_from.expanduser().resolve())])
    run(command, cwd=TRANSFORMER_TRAINER)
    report = TRANSFORMER_OUT / "training-report.html"
    if report.exists():
        print(f"  training report: {report.relative_to(REPO_ROOT)}")


def stage_distill_transformer(arguments: argparse.Namespace) -> None:
    require_tool("uv", "Install uv (https://docs.astral.sh/uv).")
    if not TRAIN_SET.exists():
        raise SystemExit(f"error: {TRAIN_SET} missing; run the augment and prune stages first")
    require_holdout_isolation(TRAIN_SET)
    teacher_checkpoint = arguments.distill_teacher_checkpoint
    if teacher_checkpoint is not None:
        teacher_checkpoint = teacher_checkpoint.expanduser().resolve()
    if teacher_checkpoint is None:
        teacher_checkpoint = TRANSFORMER_OUT / "teacher-checkpoint"
        source_checkpoint = TRANSFORMER_OUT / "checkpoint"
        if not source_checkpoint.exists():
            raise SystemExit(
                "error: current teacher checkpoint does not exist: "
                f"{source_checkpoint}; run train-transformer first"
            )
        # The standard pipeline trains the teacher immediately before this
        # stage. Refresh the snapshot every run so a stale prior student or
        # teacher can never silently become the release source.
        if teacher_checkpoint.exists():
            shutil.rmtree(teacher_checkpoint)
        shutil.copytree(source_checkpoint, teacher_checkpoint)
    if teacher_checkpoint is None or not teacher_checkpoint.exists():
        raise SystemExit(f"error: teacher checkpoint does not exist: {teacher_checkpoint}")
    config_path = teacher_checkpoint / "config.json"
    try:
        checkpoint_config = json.loads(config_path.read_text(encoding="utf-8"))
        teacher_layers = int(checkpoint_config["num_hidden_layers"])
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        raise SystemExit(f"error: teacher checkpoint has no valid layer configuration: {config_path}") from error
    if teacher_layers <= 12:
        raise SystemExit(
            "error: distillation requires a teacher deeper than the 12-layer student; "
            f"checkpoint has {teacher_layers} layers"
        )
    command = [
        "uv", "run", "distill_mmbert.py",
        "--input", str(TRAIN_SET),
        "--teacher-checkpoint", str(teacher_checkpoint),
        "--out", str(TRANSFORMER_OUT),
        "--version", arguments.version_transformer,
        "--model-abi", arguments.model_abi,
        "--backbone", arguments.backbone,
        "--device", arguments.device,
        "--release-sequence", str(arguments.release_sequence),
        "--minimum-app-build", str(arguments.minimum_app_build),
        "--maximum-app-build", str(arguments.maximum_app_build),
        "--quantize", "fp16",
        "--truncate-layers", "12",
        "--temperature", str(arguments.distill_temperature),
        "--distill-alpha", str(arguments.distill_alpha),
        "--learning-rate", str(arguments.learning_rate if arguments.learning_rate is not None else 2e-5),
        "--num-epochs", str(arguments.num_epochs),
        "--batch-size", str(arguments.batch_size),
        "--warmup-ratio", str(arguments.warmup_ratio),
        "--boundary-loss-weight", str(max(arguments.boundary_loss_weight, 2.0)),
        "--max-length", str(arguments.max_sequence_length),
        "--test-input", str(PROMOTION_TEST_SET),
        "--seed", "32",
    ]
    run(command, cwd=TRANSFORMER_TRAINER)


def stage_quantize_transformer(arguments: argparse.Namespace) -> None:
    require_tool("uv", "Install uv (https://docs.astral.sh/uv).")
    if not TRAIN_SET.exists() or not (TRANSFORMER_OUT / "SiftSignalModel.mlpackage").exists():
        raise SystemExit("error: run train-transformer before quantize-transformer")
    command = [
        "uv", "run", "quantize_candidates.py",
        "--fp16-model", str(TRANSFORMER_OUT / "SiftSignalModel.mlpackage"),
        "--source-manifest", str(TRANSFORMER_OUT / "SiftSignalModel.manifest.json"),
        "--checkpoint", str(TRANSFORMER_OUT / "checkpoint"),
        "--tokenizer-artifact", str(TRANSFORMER_OUT / "SiftSignalModel.tokenizer.siftbpe"),
        "--calibration-input", str(TRAIN_SET),
        "--fixed-holdout", str(CLASSIFICATION_TEST_SET),
        "--promotion-holdout", str(PROMOTION_TEST_SET),
        "--billing-holdout", str(BILLING_CARD_TEST_SET),
        "--conversation-holdout", str(CONVERSATION_TEST_SET),
        "--taxonomy", str(REPO_ROOT / "packages/taxonomy/taxonomy.json"),
        "--profiles", str(arguments.quantization_profiles),
        "--out", str(TRANSFORMER_OUT / "quantization-tournament"),
        "--version", arguments.version_transformer,
        "--model-abi", arguments.model_abi,
        "--release-sequence", str(arguments.release_sequence),
        "--minimum-app-build", str(arguments.minimum_app_build),
        "--maximum-app-build", str(arguments.maximum_app_build),
        "--calibration-limit", str(arguments.calibration_limit),
        "--max-length", str(arguments.max_sequence_length),
    ]
    for qat_model in arguments.qat_model:
        command.extend(["--qat-model", qat_model])
    run(command, cwd=TRANSFORMER_TRAINER)


def stage_select_transformer(arguments: argparse.Namespace) -> None:
    require_tool("python3", "Install Python 3.10+.")
    reports = TRANSFORMER_OUT / "quantization-tournament" / "reports"
    if not reports.exists():
        raise SystemExit("error: run quantize-transformer before select-transformer")
    command = [
            "python3", str(TRANSFORMER_TRAINER / "select_quantization_candidate.py"),
            "--profiles", str(arguments.quantization_profiles),
            "--reports", str(reports),
            "--out", str(TRANSFORMER_OUT / "selected-candidate.json"),
        ]
    for gate in arguments.distillation_gate:
        command.extend(["--distillation-gate", str(gate.expanduser().resolve())])
    run(command, cwd=REPO_ROOT)


def stage_finetune(arguments: argparse.Namespace) -> None:
    stage_train_transformer(arguments, finetune=True)


def main() -> None:
    arguments = parse_arguments()
    PIPELINE_DIR.mkdir(parents=True, exist_ok=True)

    if arguments.only:
        selected = [stage.strip() for stage in arguments.only.split(",") if stage.strip()]
    elif arguments.command == "all":
        selected = list(STAGES)
    else:
        selected = [arguments.command]

    skipped = {stage.strip() for stage in arguments.skip.split(",") if stage.strip()}
    unknown = (set(selected) | skipped) - set(STAGES) - {"select-transformer", "finetune"}
    if unknown:
        raise SystemExit(f"error: unknown stages: {', '.join(sorted(unknown))}")
    selected = [stage for stage in selected if stage not in skipped]

    handlers = {
        "fetch-public": stage_fetch_public,
        "fetch-remote": stage_fetch_remote,
        "curate": stage_curate,
        "augment": stage_augment,
        "prune": stage_prune,
        "train-classic": stage_train_classic,
        "train-transformer": stage_train_transformer,
        "distill-transformer": stage_distill_transformer,
        "quantize-transformer": stage_quantize_transformer,
        "select-transformer": stage_select_transformer,
        "finetune": stage_finetune,
    }

    print(f"pipeline stages: {', '.join(selected)}")
    started = time.monotonic()
    for stage in selected:
        stage_started = time.monotonic()
        print(f"\n==> {stage}")
        handlers[stage](arguments)
        print(f"<== {stage} done in {time.monotonic() - stage_started:.1f}s")

    print(f"\npipeline finished in {time.monotonic() - started:.1f}s")
    print(f"artifacts: {PIPELINE_DIR.relative_to(REPO_ROOT)}/")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
