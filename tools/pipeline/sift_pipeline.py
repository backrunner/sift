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
  train-classic      Create ML model (swift run SiftAppleTrainer --input …)
  train-transformer  frozen mmBERT Core ML model (uv run train_mmbert.py),
                     resumable via --resume-from / auto checkpoints
  finetune           incremental update: resume the latest transformer
                     checkpoint on the freshly curated corpus with a low
                     learning rate instead of retraining from scratch

Everything lands under build/pipeline/. The pipeline is deterministic given
the same inputs and seeds, and each stage validates its own inputs so a
failed stage can be re-run in isolation.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

STAGES = ["fetch-public", "fetch-remote", "curate", "train-classic", "train-transformer"]

REPO_ROOT = Path(__file__).resolve().parents[2]
APPLE_TRAINER = REPO_ROOT / "tools/apple-trainer"
TRANSFORMER_TRAINER = REPO_ROOT / "tools/transformer-trainer"
PIPELINE_DIR = REPO_ROOT / "build/pipeline"

PUBLIC_CORPUS = PIPELINE_DIR / "public-corpus.ndjson"
REMOTE_CORPUS = PIPELINE_DIR / "remote-training.ndjson"
TRAIN_SET = PIPELINE_DIR / "train.ndjson"
REJECTED_SET = PIPELINE_DIR / "rejected.ndjson"
CURATION_REPORT = PIPELINE_DIR / "curation-report.json"
CLASSIC_OUT = PIPELINE_DIR / "apple-model"
TRANSFORMER_OUT = PIPELINE_DIR / "transformer-model"
PROMOTION_TEST_SET = APPLE_TRAINER / "Evaluation" / "promotion-regressions.ndjson"


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", nargs="?", default="all", choices=["all", *STAGES, "finetune"], help="stage to run (default all)")
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
    training.add_argument("--backbone", default="jhu-clsp/mmBERT-small", help="transformer backbone")
    training.add_argument("--device", choices=["auto", "cpu", "cuda", "mps"], default="auto")
    training.add_argument("--quantize", choices=["fp16", "int8"], default="int8")
    training.add_argument("--prune-vocab", action="store_true", default=True, help="legacy SetFit option; ignored by mmBERT")
    training.add_argument("--no-prune-vocab", dest="prune_vocab", action="store_false")
    training.add_argument("--truncate-layers", type=int, default=0)
    training.add_argument("--resume-from", type=Path, default=None, help="mmBERT checkpoint dir (e.g. build/pipeline/transformer-model/checkpoint)")
    training.add_argument("--learning-rate", type=float, default=None, help="supervised fine-tuning LR; finetune defaults to 1e-5")
    training.add_argument("--body-learning-rate", type=float, default=None, help="deprecated alias for --learning-rate")
    training.add_argument("--num-epochs", type=int, default=3)
    training.add_argument("--batch-size", type=int, default=8)
    training.add_argument("--warmup-ratio", type=float, default=0.06)
    training.add_argument("--head-only", action="store_true", help="legacy SetFit option; ignored by mmBERT")
    training.add_argument("--install-ios", action="store_true", help="install trained artifacts into apps/ios/GeneratedModels")

    return parser.parse_args()


def run(command: list[str], cwd: Path, extra_env: dict[str, str] | None = None) -> None:
    print(f"  $ {' '.join(str(part) for part in command)}  (cwd={cwd.relative_to(REPO_ROOT)})")
    env = {**os.environ, **(extra_env or {})}
    result = subprocess.run(command, cwd=cwd, env=env)
    if result.returncode != 0:
        raise SystemExit(f"error: stage command failed with exit code {result.returncode}")


def require_tool(name: str, hint: str) -> None:
    if shutil.which(name) is None:
        raise SystemExit(f"error: `{name}` is required for this stage. {hint}")


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
        print(f"  skipping remote export: {message}")
        REMOTE_CORPUS.unlink(missing_ok=True)
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
    inputs = [PUBLIC_CORPUS]
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
        "--out", str(TRAIN_SET),
        "--rejected", str(REJECTED_SET),
        "--report", str(CURATION_REPORT),
        "--model-filter", arguments.model_filter,
        "--hard-floor", str(arguments.hard_floor),
        "--gray-keep", str(arguments.gray_keep),
        "--min-core-rows", str(arguments.min_core_rows),
        "--audit",
    ]
    if arguments.strict_audit:
        command.append("--strict-audit")
    run(command, cwd=TRANSFORMER_TRAINER)


def stage_train_classic(arguments: argparse.Namespace) -> None:
    require_tool("swift", "Install Xcode command line tools.")
    if not TRAIN_SET.exists():
        raise SystemExit(f"error: {TRAIN_SET} missing; run the curate stage first")
    command = [
        "swift", "run", "-q", "SiftAppleTrainer",
        "--input", str(TRAIN_SET),
        "--out", str(CLASSIC_OUT),
        "--algorithm", arguments.algorithm_classic,
        "--split-seed", str(arguments.split_seed_classic),
        "--version", arguments.version_classic,
        "--test-input", str(PROMOTION_TEST_SET),
    ]
    if arguments.install_ios:
        command.append("--install-ios")
    run(command, cwd=APPLE_TRAINER)


def stage_train_transformer(arguments: argparse.Namespace, finetune: bool = False) -> None:
    require_tool("uv", "Install uv (https://docs.astral.sh/uv).")
    if not TRAIN_SET.exists():
        raise SystemExit(f"error: {TRAIN_SET} missing; run the curate stage first")

    resume_from = arguments.resume_from
    learning_rate = arguments.learning_rate if arguments.learning_rate is not None else arguments.body_learning_rate
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
        "--backbone", arguments.backbone,
        "--device", arguments.device,
        "--quantize", arguments.quantize,
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
    if arguments.install_ios:
        command.append("--install-ios")
    run(command, cwd=TRANSFORMER_TRAINER)
    report = TRANSFORMER_OUT / "training-report.html"
    if report.exists():
        print(f"  training report: {report.relative_to(REPO_ROOT)}")


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
    unknown = (set(selected) | skipped) - set(STAGES) - {"finetune"}
    if unknown:
        raise SystemExit(f"error: unknown stages: {', '.join(sorted(unknown))}")
    selected = [stage for stage in selected if stage not in skipped]

    handlers = {
        "fetch-public": stage_fetch_public,
        "fetch-remote": stage_fetch_remote,
        "curate": stage_curate,
        "train-classic": stage_train_classic,
        "train-transformer": stage_train_transformer,
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
