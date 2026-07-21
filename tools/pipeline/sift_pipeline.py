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
  train-classic      Create ML model (swift run SiftAppleTrainer --input …)
  train-transformer  frozen FP16 mmBERT Core ML baseline
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

STAGES = ["fetch-public", "fetch-remote", "curate", "augment", "train-classic", "train-transformer", "quantize-transformer"]

REPO_ROOT = Path(__file__).resolve().parents[2]
APPLE_TRAINER = REPO_ROOT / "tools/apple-trainer"
TRANSFORMER_TRAINER = REPO_ROOT / "tools/transformer-trainer"
PIPELINE_DIR = REPO_ROOT / "build/pipeline"

PUBLIC_CORPUS = PIPELINE_DIR / "public-corpus.ndjson"
REMOTE_CORPUS = PIPELINE_DIR / "remote-training.ndjson"
TRAIN_SET = PIPELINE_DIR / "train.ndjson"
CURATED_SET = PIPELINE_DIR / "train.curated.ndjson"
REJECTED_SET = PIPELINE_DIR / "rejected.ndjson"
CURATION_REPORT = PIPELINE_DIR / "curation-report.json"
AUGMENTATION_REPORT = PIPELINE_DIR / "augmentation-report.json"
CONVERSATION_TRAIN_SET = PIPELINE_DIR / "conversation-training.ndjson"
CLASSIC_OUT = PIPELINE_DIR / "apple-model"
TRANSFORMER_OUT = PIPELINE_DIR / "transformer-model"
PROMOTION_TEST_SET = APPLE_TRAINER / "Evaluation" / "promotion-regressions.ndjson"
CLASSIFICATION_TEST_SET = APPLE_TRAINER / "Evaluation" / "classification-regressions.ndjson"
CONVERSATION_TEST_SET = TRANSFORMER_TRAINER / "Evaluation" / "conversation-regressions.ndjson"


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
        "--augmentation-config",
        type=Path,
        default=TRANSFORMER_TRAINER / "generalization-augmentation.json",
    )
    quality.add_argument("--max-augmented-per-label", type=int, default=120)
    quality.add_argument("--max-variants-per-row", type=int, default=1)

    training = parser.add_argument_group("training")
    training.add_argument("--version-classic", default="corpus-0.2")
    training.add_argument(
        "--algorithm-classic",
        choices=["maxent", "bert", "auto"],
        default="maxent",
        help="Create ML classic algorithm; maxent is the current validated default",
    )
    training.add_argument("--split-seed-classic", type=int, default=42, help="classic model holdout split seed")
    training.add_argument("--version-transformer", default="mmbert-0.1")
    training.add_argument("--model-abi", default="sift-mmbert-v3")
    training.add_argument("--backbone", default="jhu-clsp/mmBERT-small", help="transformer backbone")
    training.add_argument("--device", choices=["auto", "cpu", "cuda", "mps"], default="auto")
    training.add_argument("--quantize", choices=["fp16", "int8"], default="int8")
    training.add_argument("--quantization-profiles", type=Path, default=TRANSFORMER_TRAINER / "quantization-profiles.json")
    training.add_argument("--release-sequence", type=int, default=1)
    training.add_argument("--minimum-app-build", type=int, default=1)
    training.add_argument("--maximum-app-build", type=int, default=2_147_483_647)
    training.add_argument("--calibration-limit", type=int, default=256)
    training.add_argument(
        "--qat-model",
        action="append",
        default=[],
        metavar="PROFILE_ID=MLPACKAGE",
        help="QAT FP16 export for a W4 fallback profile; repeat for multiple profiles",
    )
    training.add_argument("--truncate-layers", type=int, default=0)
    training.add_argument("--resume-from", type=Path, default=None, help="mmBERT checkpoint dir (e.g. build/pipeline/transformer-model/checkpoint)")
    training.add_argument("--learning-rate", type=float, default=None, help="supervised fine-tuning LR; finetune defaults to 1e-5")
    training.add_argument("--num-epochs", type=int, default=3)
    training.add_argument("--batch-size", type=int, default=8)
    training.add_argument("--warmup-ratio", type=float, default=0.06)
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
    holdout_texts = (
        load_texts(CLASSIFICATION_TEST_SET)
        + load_texts(PROMOTION_TEST_SET)
        + load_texts(CONVERSATION_TEST_SET)
    )
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
    inputs = [PUBLIC_CORPUS, CONVERSATION_TRAIN_SET]
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
        "--holdout", str(CLASSIFICATION_TEST_SET),
        "--holdout", str(PROMOTION_TEST_SET),
        "--holdout", str(CONVERSATION_TEST_SET),
        "--model-filter", arguments.model_filter,
        "--hard-floor", str(arguments.hard_floor),
        "--gray-keep", str(arguments.gray_keep),
        "--min-core-rows", str(arguments.min_core_rows),
        "--remote-disagreement-keep", str(arguments.remote_disagreement_keep),
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
            "--holdout", str(CLASSIFICATION_TEST_SET),
            "--holdout", str(PROMOTION_TEST_SET),
            "--holdout", str(CONVERSATION_TEST_SET),
            "--taxonomy", str(REPO_ROOT / "packages/taxonomy/taxonomy.json"),
            "--out", str(TRAIN_SET),
            "--report", str(AUGMENTATION_REPORT),
            "--max-augmented-per-label", str(arguments.max_augmented_per_label),
            "--max-variants-per-row", str(arguments.max_variants_per_row),
        ],
        cwd=REPO_ROOT,
    )


def stage_train_classic(arguments: argparse.Namespace) -> None:
    require_tool("swift", "Install Xcode command line tools.")
    if not TRAIN_SET.exists():
        raise SystemExit(f"error: {TRAIN_SET} missing; run the curate stage first")
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
            "--conversation", str(CONVERSATION_TEST_SET),
            "--output", str(CLASSIC_OUT / "classic-message-filter-report.json"),
        ],
        cwd=REPO_ROOT,
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
        raise SystemExit(f"error: {TRAIN_SET} missing; run the curate stage first")
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
        "--quantize", "fp16",
        "--learning-rate", str(learning_rate),
        "--num-epochs", str(arguments.num_epochs),
        "--batch-size", str(arguments.batch_size),
        "--warmup-ratio", str(arguments.warmup_ratio),
        "--test-input", str(PROMOTION_TEST_SET),
    ]
    if arguments.truncate_layers > 0:
        command.extend(["--truncate-layers", str(arguments.truncate_layers)])
    if resume_from is not None:
        command.extend(["--resume-from", str(resume_from.expanduser().resolve())])
    run(command, cwd=TRANSFORMER_TRAINER)
    report = TRANSFORMER_OUT / "training-report.html"
    if report.exists():
        print(f"  training report: {report.relative_to(REPO_ROOT)}")


def stage_quantize_transformer(arguments: argparse.Namespace) -> None:
    require_tool("uv", "Install uv (https://docs.astral.sh/uv).")
    if not TRAIN_SET.exists() or not (TRANSFORMER_OUT / "SiftTransformerClassifier.mlpackage").exists():
        raise SystemExit("error: run train-transformer before quantize-transformer")
    command = [
        "uv", "run", "quantize_candidates.py",
        "--fp16-model", str(TRANSFORMER_OUT / "SiftTransformerClassifier.mlpackage"),
        "--checkpoint", str(TRANSFORMER_OUT / "checkpoint"),
        "--tokenizer-artifact", str(TRANSFORMER_OUT / "SiftTransformerClassifier.tokenizer.siftbpe"),
        "--calibration-input", str(TRAIN_SET),
        "--fixed-holdout", str(CLASSIFICATION_TEST_SET),
        "--promotion-holdout", str(PROMOTION_TEST_SET),
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
    ]
    for qat_model in arguments.qat_model:
        command.extend(["--qat-model", qat_model])
    run(command, cwd=TRANSFORMER_TRAINER)


def stage_select_transformer(arguments: argparse.Namespace) -> None:
    require_tool("python3", "Install Python 3.10+.")
    reports = TRANSFORMER_OUT / "quantization-tournament" / "reports"
    if not reports.exists():
        raise SystemExit("error: run quantize-transformer before select-transformer")
    run(
        [
            "python3", str(TRANSFORMER_TRAINER / "select_quantization_candidate.py"),
            "--profiles", str(arguments.quantization_profiles),
            "--reports", str(reports),
            "--out", str(TRANSFORMER_OUT / "selected-candidate.json"),
        ],
        cwd=REPO_ROOT,
    )


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
        "train-classic": stage_train_classic,
        "train-transformer": stage_train_transformer,
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
