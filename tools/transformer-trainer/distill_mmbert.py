#!/usr/bin/env python3
"""Distill a current Sift Signal checkpoint into a smaller ModernBERT student.

The teacher is kept frozen and supplies softened class probabilities while the
student is trained on the same leak-free labelled corpus.  The student starts
from the teacher weights and can be structurally reduced with
``--truncate-layers``; this keeps the tokenizer and output-label contract
identical to the production model.  Exported artifacts use the same Core ML
and manifest format as ``train_mmbert.py`` and can therefore enter the normal
quantization tournament.

This is deliberately a separate entry point.  A normal pipeline run never
silently changes the production Signal model to a distilled candidate.
"""

from __future__ import annotations

import argparse
import json
import shutil
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from model_contract import MODEL_ABI_V1, model_labels
from train_mmbert import (
    directory_sha256,
    evaluate_model,
    export_coreml,
    file_sha256,
    load_rows,
    make_collate,
    remote_artifacts,
    stratified_split,
    TextDataset,
    tokenizer_kind,
    write_tokenizer_artifact,
    write_training_report,
)


@dataclass
class Arguments:
    input: Path
    teacher_checkpoint: Path
    taxonomy: Path | None
    out: Path
    backbone: str
    model_name: str
    version: str
    languages: list[str]
    max_length: int
    validation_fraction: float
    num_epochs: int
    batch_size: int
    learning_rate: float
    weight_decay: float
    warmup_ratio: float
    label_smoothing: float
    boundary_loss_weight: float
    temperature: float
    distill_alpha: float
    truncate_layers: int
    quantize: str
    quantization_profile: str
    release_sequence: int
    model_abi: str
    minimum_app_build: int
    maximum_app_build: int
    device: str
    test_input: Path | None
    save_checkpoint: str
    skip_export: bool
    max_rows: int | None
    seed: int


def locate_repo_root() -> Path:
    directory = Path(__file__).resolve().parent
    while directory != directory.parent:
        if (directory / "packages/taxonomy/taxonomy.json").exists():
            return directory
        directory = directory.parent
    raise SystemExit("error: could not locate repo root containing packages/taxonomy/taxonomy.json")


def parse_arguments() -> Arguments:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="leak-free text/label NDJSON corpus")
    parser.add_argument("--teacher-checkpoint", type=Path, required=True, help="frozen teacher checkpoint directory")
    parser.add_argument(
        "--taxonomy",
        type=Path,
        default=None,
        help="taxonomy contract; defaults to the repository taxonomy",
    )
    parser.add_argument("--out", type=Path, required=True, help="student artifact output directory")
    parser.add_argument("--backbone", default="jhu-clsp/mmBERT-small", help="backbone name recorded in the manifest")
    parser.add_argument("--model-name", default="SiftSignalModel")
    parser.add_argument("--version", default="signal-distilled-v1")
    parser.add_argument(
        "--languages",
        default="zh,en,es,pt,fr,de,ru,ja,ko,id,vi,th",
        help="comma-separated language tags recorded in the manifest",
    )
    parser.add_argument("--max-length", type=int, default=96)
    parser.add_argument("--validation-fraction", type=float, default=0.1)
    parser.add_argument("--num-epochs", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--learning-rate", type=float, default=2e-5)
    parser.add_argument("--weight-decay", type=float, default=0.01)
    parser.add_argument("--warmup-ratio", type=float, default=0.06)
    parser.add_argument("--label-smoothing", type=float, default=0.0)
    parser.add_argument("--boundary-loss-weight", type=float, default=1.0)
    parser.add_argument("--temperature", type=float, default=2.0, help="soft-target temperature, >= 1")
    parser.add_argument(
        "--distill-alpha",
        type=float,
        default=0.7,
        help="soft-target loss weight; the remaining weight is hard-label CE",
    )
    parser.add_argument("--truncate-layers", type=int, default=12, help="number of ModernBERT layers kept in the student")
    parser.add_argument("--quantize", choices=["fp16", "int8"], default="int8")
    parser.add_argument("--quantization-profile", default=None)
    parser.add_argument("--release-sequence", type=int, default=0)
    parser.add_argument("--model-abi", default=MODEL_ABI_V1)
    parser.add_argument("--minimum-app-build", type=int, default=1)
    parser.add_argument("--maximum-app-build", type=int, default=2_147_483_647)
    parser.add_argument("--device", choices=["auto", "cpu", "cuda", "mps"], default="auto")
    parser.add_argument("--test-input", type=Path, default=None)
    parser.add_argument("--save-checkpoint", default="auto", help="'auto' = <out>/checkpoint, 'off' disables saving")
    parser.add_argument("--skip-export", action="store_true", help="skip Core ML/tokenizer/manifest export")
    parser.add_argument("--max-rows", type=int, default=None, help="debug/smoke: cap input rows")
    parser.add_argument("--seed", type=int, default=42)
    raw = parser.parse_args()
    if raw.temperature < 1.0:
        parser.error("--temperature must be at least 1")
    if not 0.0 <= raw.distill_alpha <= 1.0:
        parser.error("--distill-alpha must be between 0 and 1")
    if raw.boundary_loss_weight < 1.0:
        parser.error("--boundary-loss-weight must be at least 1")
    if raw.truncate_layers <= 0:
        parser.error("--truncate-layers must be positive")
    return Arguments(
        input=raw.input.expanduser().resolve(),
        teacher_checkpoint=raw.teacher_checkpoint.expanduser().resolve(),
        taxonomy=(raw.taxonomy.expanduser().resolve() if raw.taxonomy else None),
        out=raw.out.expanduser().resolve(),
        backbone=raw.backbone,
        model_name=raw.model_name,
        version=raw.version,
        languages=[item.strip() for item in raw.languages.split(",") if item.strip()],
        max_length=raw.max_length,
        validation_fraction=raw.validation_fraction,
        num_epochs=raw.num_epochs,
        batch_size=raw.batch_size,
        learning_rate=raw.learning_rate,
        weight_decay=raw.weight_decay,
        warmup_ratio=raw.warmup_ratio,
        label_smoothing=raw.label_smoothing,
        boundary_loss_weight=raw.boundary_loss_weight,
        temperature=raw.temperature,
        distill_alpha=raw.distill_alpha,
        truncate_layers=raw.truncate_layers,
        quantize=raw.quantize,
        quantization_profile=raw.quantization_profile or ("fp16-baseline" if raw.quantize == "fp16" else "w8a16-channel-ptq"),
        release_sequence=raw.release_sequence,
        model_abi=raw.model_abi,
        minimum_app_build=raw.minimum_app_build,
        maximum_app_build=raw.maximum_app_build,
        device=raw.device,
        test_input=(raw.test_input.expanduser().resolve() if raw.test_input else None),
        save_checkpoint=raw.save_checkpoint,
        skip_export=raw.skip_export,
        max_rows=raw.max_rows,
        seed=raw.seed,
    )


def select_device(requested: str) -> str:
    import torch

    cuda_available = torch.cuda.is_available()
    mps_available = bool(getattr(torch.backends, "mps", None)) and torch.backends.mps.is_available()
    if requested == "cuda" and not cuda_available:
        raise SystemExit("error: --device cuda requested but torch.cuda.is_available() is False")
    if requested == "mps" and not mps_available:
        raise SystemExit("error: --device mps requested but MPS is unavailable")
    if requested != "auto":
        return requested
    if cuda_available:
        return "cuda"
    if mps_available:
        return "mps"
    return "cpu"


def describe_device(device: str) -> str:
    import torch

    if device == "cuda":
        return f"cuda ({torch.cuda.get_device_name(0) if torch.cuda.device_count() else 'unknown GPU'})"
    if device == "mps":
        return "mps (Apple Silicon GPU via Metal)"
    return "cpu"


def checkpoint_labels(checkpoint: Path) -> list[str]:
    config_path = checkpoint / "config.json"
    if not config_path.exists():
        raise SystemExit(f"error: teacher checkpoint is missing config.json: {checkpoint}")
    document = json.loads(config_path.read_text(encoding="utf-8"))
    mapping = document.get("id2label", {})
    try:
        labels = [str(mapping[str(index)] if str(index) in mapping else mapping[index]) for index in range(len(mapping))]
    except (KeyError, TypeError, ValueError) as error:
        raise SystemExit("error: teacher checkpoint has an invalid dense id2label mapping") from error
    if not labels or len(labels) != len(set(labels)):
        raise SystemExit("error: teacher checkpoint labels must be non-empty and unique")
    return labels


def taxonomy_labels(path: Path) -> set[str]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        labels = {
            str(leaf["id"])
            for group in document["groups"]
            for leaf in group["leaves"]
        }
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise SystemExit(f"error: invalid taxonomy contract {path}: {error}") from error
    if not labels:
        raise SystemExit(f"error: taxonomy contract contains no labels: {path}")
    return labels


def validate_label_contract(
    teacher_labels: list[str],
    corpus_labels: set[str],
    taxonomy_leaf_labels: set[str],
) -> None:
    expected_labels = model_labels(taxonomy_leaf_labels)
    teacher_label_set = set(teacher_labels)
    if teacher_label_set != expected_labels:
        missing = sorted(expected_labels - teacher_label_set)
        extra = sorted(teacher_label_set - expected_labels)
        raise SystemExit(
            "error: teacher checkpoint does not match the selected taxonomy contract; "
            f"missing={missing or 'none'} extra={extra or 'none'}"
        )
    if corpus_labels != teacher_label_set:
        missing = sorted(teacher_label_set - corpus_labels)
        extra = sorted(corpus_labels - teacher_label_set)
        raise SystemExit(
            "error: student corpus must preserve the teacher label contract; "
            f"missing={missing or 'none'} extra={extra or 'none'}"
        )


def truncate_modernbert_layers(model, keep: int) -> None:
    import torch

    layers = getattr(getattr(model, "model", None), "layers", None)
    if layers is None:
        raise SystemExit("error: --truncate-layers is only implemented for ModernBERT-style models")
    if keep >= len(layers):
        print(f"student keeps all {len(layers)} teacher layers")
        return
    model.model.layers = torch.nn.ModuleList(list(layers)[:keep])
    model.config.num_hidden_layers = keep
    model.model.config.num_hidden_layers = keep
    print(f"student truncated to {keep} layers")


def distillation_loss(
    student_logits,
    teacher_logits,
    labels,
    temperature: float,
    alpha: float,
    label_smoothing: float,
):
    """Return per-row hard-label and soft-teacher losses.

    Keeping the row dimension until after the boundary/source weights are
    applied makes this equivalent to the normal trainer's weighting policy.
    """
    import torch
    import torch.nn.functional as functional

    hard = functional.cross_entropy(
        student_logits,
        labels,
        label_smoothing=label_smoothing,
        reduction="none",
    )
    teacher_probabilities = functional.softmax(teacher_logits / temperature, dim=-1)
    student_log_probabilities = functional.log_softmax(student_logits / temperature, dim=-1)
    soft = functional.kl_div(
        student_log_probabilities,
        teacher_probabilities,
        reduction="none",
    ).sum(dim=-1) * (temperature * temperature)
    return (alpha * soft) + ((1.0 - alpha) * hard)


def train_student(
    student,
    teacher,
    tokenizer,
    rows: list[dict[str, str]],
    label_to_id: dict[str, int],
    arguments: Arguments,
    device: str,
) -> list[dict]:
    import torch
    from torch.utils.data import DataLoader
    from transformers import get_linear_schedule_with_warmup

    generator = torch.Generator()
    generator.manual_seed(arguments.seed)
    loader = DataLoader(
        TextDataset(rows, label_to_id),
        batch_size=arguments.batch_size,
        shuffle=True,
        collate_fn=make_collate(tokenizer, arguments.max_length, arguments.boundary_loss_weight),
        generator=generator,
    )
    student.to(device).train()
    teacher.to(device).eval()
    teacher.requires_grad_(False)
    trainable_parameters = [parameter for parameter in student.parameters() if parameter.requires_grad]
    if not trainable_parameters:
        raise SystemExit("error: no trainable student parameters remain")
    optimizer = torch.optim.AdamW(trainable_parameters, lr=arguments.learning_rate, weight_decay=arguments.weight_decay)
    total_steps = max(len(loader) * arguments.num_epochs, 1)
    warmup_steps = int(total_steps * arguments.warmup_ratio)
    scheduler = get_linear_schedule_with_warmup(optimizer, warmup_steps, total_steps)
    losses: list[dict] = []
    step = 0
    for epoch in range(arguments.num_epochs):
        for batch in loader:
            step += 1
            batch = {key: value.to(device) for key, value in batch.items()}
            labels = batch.pop("labels")
            loss_weights = batch.pop("loss_weights")
            optimizer.zero_grad(set_to_none=True)
            with torch.no_grad():
                teacher_logits = teacher(**batch).logits
            student_logits = student(**batch).logits
            losses_per_row = distillation_loss(
                student_logits,
                teacher_logits,
                labels,
                arguments.temperature,
                arguments.distill_alpha,
                arguments.label_smoothing,
            )
            loss = (losses_per_row * loss_weights).sum() / loss_weights.sum()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(trainable_parameters, 1.0)
            optimizer.step()
            scheduler.step()
            if step == 1 or step % 25 == 0 or step == total_steps:
                point = {
                    "step": step,
                    "epoch": epoch + 1,
                    "loss": float(loss.detach().cpu()),
                }
                losses.append(point)
                print(f"step {step}/{total_steps} epoch {epoch + 1}/{arguments.num_epochs} loss {point['loss']:.4f}")
    return losses


def write_summary(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"summary: {path}")


def runtime_validation_metrics(promotion_accuracy: float | None) -> dict:
    """Return the validation schema decoded by TransformerModelManifest."""
    return {
        "fixedAccuracy": 0.0,
        "promotionAccuracy": promotion_accuracy or 0.0,
        "fp16Agreement": 0.0,
        "languageAccuracy": {},
    }


def main() -> None:
    arguments = parse_arguments()
    if not arguments.input.exists():
        raise SystemExit(f"error: input corpus does not exist: {arguments.input}")
    if not arguments.teacher_checkpoint.exists():
        raise SystemExit(f"error: teacher checkpoint does not exist: {arguments.teacher_checkpoint}")

    repo_root = locate_repo_root()
    taxonomy_path = arguments.taxonomy or (repo_root / "packages/taxonomy/taxonomy.json")
    if not taxonomy_path.exists():
        raise SystemExit(f"error: taxonomy contract does not exist: {taxonomy_path}")
    rows = load_rows(arguments.input, max_rows=arguments.max_rows)
    teacher_labels = checkpoint_labels(arguments.teacher_checkpoint)
    corpus_labels = {row["label"] for row in rows}
    validate_label_contract(teacher_labels, corpus_labels, taxonomy_labels(taxonomy_path))
    # Preserve the teacher's output order exactly; logits are only comparable
    # when every column keeps the same label identity.
    labels = teacher_labels
    label_to_id = {label: index for index, label in enumerate(labels)}
    id_to_label = {index: label for label, index in label_to_id.items()}
    training_rows, validation_rows = stratified_split(rows, arguments.validation_fraction, arguments.seed)
    print(f"rows: {len(rows)} total, {len(training_rows)} train, {len(validation_rows)} validation, {len(labels)} labels")

    import torch
    from transformers import AutoConfig, AutoModelForSequenceClassification, AutoTokenizer, set_seed

    set_seed(arguments.seed)
    device = select_device(arguments.device)
    print(f"device: {describe_device(device)}")
    tokenizer = AutoTokenizer.from_pretrained(arguments.teacher_checkpoint)
    teacher = AutoModelForSequenceClassification.from_pretrained(arguments.teacher_checkpoint)
    teacher_config = AutoConfig.from_pretrained(
        arguments.teacher_checkpoint,
        num_labels=len(labels),
        id2label=id_to_label,
        label2id=label_to_id,
    )
    if getattr(teacher_config, "num_labels", len(labels)) != len(labels):
        raise SystemExit("error: teacher classifier output size does not match the label contract")
    student = AutoModelForSequenceClassification.from_pretrained(
        arguments.teacher_checkpoint,
        config=teacher_config,
        ignore_mismatched_sizes=False,
    )
    teacher_layer_count = int(getattr(teacher.config, "num_hidden_layers", 0))
    if arguments.truncate_layers > teacher_layer_count:
        raise SystemExit(
            f"error: --truncate-layers {arguments.truncate_layers} exceeds teacher depth {teacher_layer_count}"
        )
    truncate_modernbert_layers(student, arguments.truncate_layers)
    student.config.problem_type = "single_label_classification"

    losses = train_student(
        student,
        teacher,
        tokenizer,
        training_rows,
        label_to_id,
        arguments,
        device,
    )
    student_accuracy, per_label, prediction_pairs, _ = evaluate_model(
        student,
        tokenizer,
        validation_rows,
        label_to_id,
        labels,
        arguments.max_length,
        device,
    )
    teacher_accuracy, _, _, _ = evaluate_model(
        teacher,
        tokenizer,
        validation_rows,
        label_to_id,
        labels,
        arguments.max_length,
        device,
    )
    print(f"student validation accuracy: {student_accuracy:.4f}")
    print(f"teacher validation accuracy: {teacher_accuracy:.4f}")

    test_accuracy: float | None = None
    test_rows: list[dict[str, str]] = []
    if arguments.test_input is not None:
        test_rows = load_rows(arguments.test_input)
        test_unknown = {row["label"] for row in test_rows} - set(label_to_id)
        if test_unknown:
            raise SystemExit(
                "error: labels in --test-input are absent from the teacher contract: "
                + ", ".join(sorted(test_unknown))
            )
        test_accuracy, _, _, _ = evaluate_model(
            student,
            tokenizer,
            test_rows,
            label_to_id,
            labels,
            arguments.max_length,
            device,
        )
        print(f"student test accuracy: {test_accuracy:.4f}")

    out = arguments.out
    out.mkdir(parents=True, exist_ok=True)
    if arguments.save_checkpoint != "off":
        checkpoint_dir = out / "checkpoint" if arguments.save_checkpoint == "auto" else Path(arguments.save_checkpoint).expanduser().resolve()
        checkpoint_dir.mkdir(parents=True, exist_ok=True)
        student.save_pretrained(checkpoint_dir)
        tokenizer.save_pretrained(checkpoint_dir)
        print(f"checkpoint: {checkpoint_dir}")

    summary = {
        "schemaVersion": 1,
        "version": arguments.version,
        "algorithm": "teacher-student-distillation",
        "teacherCheckpointSHA256": directory_sha256(arguments.teacher_checkpoint),
        "taxonomySHA256": file_sha256(taxonomy_path),
        "teacherLayers": teacher_layer_count,
        "studentLayers": arguments.truncate_layers,
        "validationAccuracy": student_accuracy,
        "teacherValidationAccuracy": teacher_accuracy,
        "testAccuracy": test_accuracy,
        "trainingCount": len(training_rows),
        "validationCount": len(validation_rows),
        "testCount": len(test_rows),
        "hyperparameters": {
            "numEpochs": arguments.num_epochs,
            "batchSize": arguments.batch_size,
            "learningRate": arguments.learning_rate,
            "weightDecay": arguments.weight_decay,
            "warmupRatio": arguments.warmup_ratio,
            "labelSmoothing": arguments.label_smoothing,
            "boundaryLossWeight": arguments.boundary_loss_weight,
            "temperature": arguments.temperature,
            "distillAlpha": arguments.distill_alpha,
            "maxLength": arguments.max_length,
            "seed": arguments.seed,
        },
        "labels": labels,
    }
    if arguments.skip_export:
        write_training_report(
            out,
            arguments,
            student_accuracy,
            per_label,
            prediction_pairs,
            losses,
            Counter(row["label"] for row in training_rows),
        )
        write_summary(out / "distillation-summary.json", summary)
        print("export skipped")
        return

    package_path = out / f"{arguments.model_name}.mlpackage"
    if package_path.exists():
        shutil.rmtree(package_path)
    mlmodel = export_coreml(student, labels, arguments.max_length, arguments.quantize)
    mlmodel.save(str(package_path))
    tokenizer_path = write_tokenizer_artifact(tokenizer, out, arguments.model_name)
    downloadable_artifacts = remote_artifacts([package_path, tokenizer_path], out)
    manifest = {
        "schemaVersion": 2,
        "releaseSequence": arguments.release_sequence,
        "modelABI": arguments.model_abi,
        "minimumAppBuild": arguments.minimum_app_build,
        "maximumAppBuild": arguments.maximum_app_build,
        "minimumOSVersion": "18.0",
        "runtimeProfile": {
            "computeUnits": "cpuOnly",
            "modelType": "mlProgram",
            "inferenceBudgetMilliseconds": 500,
        },
        "quantizationProfile": {
            "identifier": arguments.quantization_profile,
            "weightBits": 16 if arguments.quantize == "fp16" else 8,
            "activationBits": 16,
            "method": "baseline" if arguments.quantize == "fp16" else "ptq",
            "granularity": "per-tensor" if arguments.quantize == "fp16" else "per-channel",
        },
        "distillation": {
            "teacherCheckpointSHA256": summary["teacherCheckpointSHA256"],
            "teacherLayers": teacher_layer_count,
            "studentLayers": arguments.truncate_layers,
            "temperature": arguments.temperature,
            "distillAlpha": arguments.distill_alpha,
        },
        "validationMetrics": runtime_validation_metrics(test_accuracy),
        "version": arguments.version,
        "trainedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
        "algorithm": "teacher-student-distillation",
        "backbone": arguments.backbone,
        "languages": arguments.languages,
        "labels": labels,
        "maxSequenceLength": arguments.max_length,
        "doLowerCase": bool(getattr(tokenizer, "do_lower_case", False)),
        "tokenizerKind": tokenizer_kind(tokenizer),
        "tokenizerArtifact": tokenizer_path.name,
        "modelArtifact": package_path.name,
        "sha256": directory_sha256(package_path),
        "taxonomyHash": summary["taxonomySHA256"],
        "tokenizerSHA256": file_sha256(tokenizer_path),
        "remoteArtifacts": downloadable_artifacts,
        "downloadBytes": sum(item["byteCount"] for item in downloadable_artifacts),
        "validationAccuracy": student_accuracy,
        "trainingCount": len(training_rows),
        "validationCount": len(validation_rows),
    }
    manifest_path = out / f"{arguments.model_name}.manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    write_training_report(
        out,
        arguments,
        student_accuracy,
        per_label,
        prediction_pairs,
        losses,
        Counter(row["label"] for row in training_rows),
    )
    write_summary(out / "distillation-summary.json", summary)
    print(f"model: {package_path}")
    print(f"tokenizer: {tokenizer_path}")
    print(f"manifest: {manifest_path}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit(130)
