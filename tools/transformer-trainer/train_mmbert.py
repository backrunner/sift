#!/usr/bin/env python3
"""Train the Sift transformer variant with mmBERT and export Core ML.

This trainer uses supervised fine-tuning (`AutoModelForSequenceClassification`)
instead of SetFit. The default backbone is `jhu-clsp/mmBERT-small`, a
ModernBERT multilingual encoder with a Gemma-style metaspace BPE tokenizer.

Artifacts:

  SiftTransformerClassifier.mlpackage       Core ML classifier
  SiftTransformerClassifier.tokenizer.json  Hugging Face tokenizer JSON
  SiftTransformerClassifier.manifest.json   iOS loader metadata

The Core ML model takes `input_ids` / `attention_mask` int32 tensors of shape
`[1, max_length]` and emits a Core ML classifier label plus probabilities.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import shutil
import sys
import tempfile
import types
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

MODEL_INPUT_IDS = "input_ids"
MODEL_ATTENTION_MASK = "attention_mask"
DEFAULT_BACKBONE = "jhu-clsp/mmBERT-small"


@dataclass
class Arguments:
    input: Path
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
    classifier_dropout: float | None
    attention_dropout: float | None
    embedding_dropout: float | None
    mlp_dropout: float | None
    classifier_pooling: str | None
    freeze_encoder: bool
    truncate_layers: int
    quantize: str
    device: str
    resume_from: Path | None
    save_checkpoint: str
    install_ios: bool
    max_rows: int | None
    test_input: Path | None
    write_predictions: Path | None
    skip_export: bool
    seed: int


def parse_arguments() -> Arguments:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=Path, required=True, help="text/label NDJSON corpus")
    parser.add_argument("--out", type=Path, default=None, help="output directory (default build/transformer-model)")
    parser.add_argument("--backbone", default=DEFAULT_BACKBONE, help="mmBERT/ModernBERT sequence-classification backbone")
    parser.add_argument("--model-name", default="SiftTransformerClassifier")
    parser.add_argument("--version", default="mmbert-0.1")
    parser.add_argument(
        "--languages",
        default="zh,en,es,pt,fr,de,ru,ja,ko,id,vi,th",
        help="comma-separated language tags recorded in the manifest",
    )
    parser.add_argument("--max-length", type=int, default=96, help="token sequence length")
    parser.add_argument("--validation-fraction", type=float, default=0.1)
    parser.add_argument("--num-epochs", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--learning-rate", type=float, default=2e-5)
    parser.add_argument("--weight-decay", type=float, default=0.01)
    parser.add_argument("--warmup-ratio", type=float, default=0.06)
    parser.add_argument("--label-smoothing", type=float, default=0.0, help="CrossEntropy label smoothing")
    parser.add_argument("--classifier-dropout", type=float, default=None, help="override config.classifier_dropout")
    parser.add_argument("--attention-dropout", type=float, default=None, help="override config.attention_dropout")
    parser.add_argument("--embedding-dropout", type=float, default=None, help="override config.embedding_dropout")
    parser.add_argument("--mlp-dropout", type=float, default=None, help="override config.mlp_dropout")
    parser.add_argument("--classifier-pooling", choices=["cls", "mean"], default=None, help="override config.classifier_pooling")
    parser.add_argument("--freeze-encoder", action="store_true", help="train only the classification head")
    parser.add_argument("--truncate-layers", type=int, default=0, help="keep only the first N encoder layers before training")
    parser.add_argument("--quantize", choices=["fp16", "int8"], default="int8")
    parser.add_argument("--device", choices=["auto", "cpu", "cuda", "mps"], default="auto")
    parser.add_argument("--resume-from", type=Path, default=None, help="checkpoint dir produced by this trainer")
    parser.add_argument("--save-checkpoint", default="auto", help="'auto' = <out>/checkpoint, 'off' disables saving")
    parser.add_argument("--install-ios", action="store_true", help="copy artifacts into apps/ios/GeneratedModels")
    parser.add_argument("--max-rows", type=int, default=None, help="debug/smoke: cap rows before splitting")
    parser.add_argument("--test-input", type=Path, default=None, help="optional held-out NDJSON evaluated after validation")
    parser.add_argument("--write-predictions", type=Path, default=None, help="write validation/test prediction rows as NDJSON")
    parser.add_argument("--skip-export", action="store_true", help="skip Core ML/tokenizer/manifest export for tuning runs")
    parser.add_argument("--seed", type=int, default=42)
    raw = parser.parse_args()

    repo_root = locate_repo_root()
    return Arguments(
        input=raw.input.expanduser().resolve(),
        out=(raw.out.expanduser().resolve() if raw.out else repo_root / "build/transformer-model"),
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
        classifier_dropout=raw.classifier_dropout,
        attention_dropout=raw.attention_dropout,
        embedding_dropout=raw.embedding_dropout,
        mlp_dropout=raw.mlp_dropout,
        classifier_pooling=raw.classifier_pooling,
        freeze_encoder=raw.freeze_encoder,
        truncate_layers=raw.truncate_layers,
        quantize=raw.quantize,
        device=raw.device,
        resume_from=(raw.resume_from.expanduser().resolve() if raw.resume_from else None),
        save_checkpoint=raw.save_checkpoint,
        install_ios=raw.install_ios,
        max_rows=raw.max_rows,
        test_input=(raw.test_input.expanduser().resolve() if raw.test_input else None),
        write_predictions=(raw.write_predictions.expanduser().resolve() if raw.write_predictions else None),
        skip_export=raw.skip_export,
        seed=raw.seed,
    )


def locate_repo_root() -> Path:
    directory = Path(__file__).resolve().parent
    while directory != directory.parent:
        if (directory / "packages/taxonomy/taxonomy.json").exists():
            return directory
        directory = directory.parent
    raise SystemExit("error: could not locate repo root containing packages/taxonomy/taxonomy.json")


def load_rows(path: Path, max_rows: int | None = None) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            text, label = record.get("text", "").strip(), record.get("label", "").strip()
            if text and label:
                rows.append({"text": text, "label": label})
                if max_rows is not None and len(rows) >= max_rows:
                    break
    if not rows:
        raise SystemExit(f"error: dataset is empty: {path}")
    return rows


def load_taxonomy_labels(repo_root: Path) -> set[str]:
    document = json.loads((repo_root / "packages/taxonomy/taxonomy.json").read_text(encoding="utf-8"))
    return {leaf["id"] for group in document["groups"] for leaf in group["leaves"]}


def stratified_split(
    rows: list[dict[str, str]], fraction: float, seed: int
) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    rng = random.Random(seed)
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        grouped[row["label"]].append(row)

    training: list[dict[str, str]] = []
    validation: list[dict[str, str]] = []
    for label in sorted(grouped):
        bucket = grouped[label][:]
        rng.shuffle(bucket)
        holdout = int(len(bucket) * fraction) if len(bucket) >= 5 else 0
        validation.extend(bucket[:holdout])
        training.extend(bucket[holdout:])
    rng.shuffle(training)
    rng.shuffle(validation)
    return training, validation


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


class TextDataset:
    def __init__(self, rows: list[dict[str, str]], label_to_id: dict[str, int]):
        self.rows = rows
        self.label_to_id = label_to_id

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int) -> dict[str, str | int]:
        row = self.rows[index]
        return {"text": row["text"], "label": self.label_to_id[row["label"]]}


def make_collate(tokenizer, max_length: int):
    import torch

    def collate(batch: list[dict[str, str | int]]) -> dict[str, "torch.Tensor"]:
        encoded = tokenizer(
            [str(item["text"]) for item in batch],
            truncation=True,
            padding="max_length",
            max_length=max_length,
            return_tensors="pt",
        )
        encoded["labels"] = torch.tensor([int(item["label"]) for item in batch], dtype=torch.long)
        return encoded

    return collate


def train_model(model, tokenizer, rows: list[dict[str, str]], label_to_id: dict[str, int], arguments: Arguments, device: str):
    import torch
    from torch.utils.data import DataLoader
    from transformers import get_linear_schedule_with_warmup

    if arguments.num_epochs <= 0:
        return []

    generator = torch.Generator()
    generator.manual_seed(arguments.seed)
    dataset = TextDataset(rows, label_to_id)
    loader = DataLoader(
        dataset,
        batch_size=arguments.batch_size,
        shuffle=True,
        collate_fn=make_collate(tokenizer, arguments.max_length),
        generator=generator,
    )
    model.to(device)
    model.train()
    trainable_parameters = [parameter for parameter in model.parameters() if parameter.requires_grad]
    if not trainable_parameters:
        raise SystemExit("error: no trainable parameters remain")
    optimizer = torch.optim.AdamW(trainable_parameters, lr=arguments.learning_rate, weight_decay=arguments.weight_decay)
    loss_fn = (
        torch.nn.CrossEntropyLoss(label_smoothing=arguments.label_smoothing)
        if arguments.label_smoothing > 0
        else None
    )
    total_steps = max(len(loader) * arguments.num_epochs, 1)
    warmup_steps = int(total_steps * arguments.warmup_ratio)
    scheduler = get_linear_schedule_with_warmup(optimizer, warmup_steps, total_steps)
    losses: list[dict] = []
    step = 0
    for epoch in range(arguments.num_epochs):
        for batch in loader:
            step += 1
            batch = {key: value.to(device) for key, value in batch.items()}
            optimizer.zero_grad(set_to_none=True)
            if loss_fn is None:
                output = model(**batch)
                loss = output.loss
            else:
                labels = batch.pop("labels")
                output = model(**batch)
                loss = loss_fn(output.logits, labels)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(trainable_parameters, 1.0)
            optimizer.step()
            scheduler.step()
            if step == 1 or step % 25 == 0 or step == total_steps:
                point = {"step": step, "epoch": epoch + 1, "loss": float(loss.detach().cpu())}
                losses.append(point)
                print(f"step {step}/{total_steps} epoch {epoch + 1}/{arguments.num_epochs} loss {point['loss']:.4f}")
    return losses


def evaluate_model(model, tokenizer, rows: list[dict[str, str]], label_to_id: dict[str, int], labels: list[str], max_length: int, device: str):
    import torch
    from torch.utils.data import DataLoader

    if not rows:
        return 0.0, {}, []
    dataset = TextDataset(rows, label_to_id)
    loader = DataLoader(dataset, batch_size=32, shuffle=False, collate_fn=make_collate(tokenizer, max_length))
    model.to(device)
    model.eval()
    expected_ids: list[int] = []
    predicted_ids: list[int] = []
    confidences: list[float] = []
    with torch.no_grad():
        for batch in loader:
            expected_ids.extend(int(item) for item in batch.pop("labels").tolist())
            batch = {key: value.to(device) for key, value in batch.items()}
            logits = model(**batch).logits
            probabilities = torch.softmax(logits, dim=-1)
            confidence, prediction = probabilities.max(dim=-1)
            predicted_ids.extend(int(item) for item in prediction.detach().cpu().tolist())
            confidences.extend(float(item) for item in confidence.detach().cpu().tolist())

    per_label_total: Counter[str] = Counter(labels[index] for index in expected_ids)
    per_label_correct: Counter[str] = Counter()
    pairs: list[tuple[str, str]] = []
    for want_id, got_id in zip(expected_ids, predicted_ids):
        want, got = labels[want_id], labels[got_id]
        pairs.append((want, got))
        if want == got:
            per_label_correct[want] += 1
    accuracy = sum(per_label_correct.values()) / len(expected_ids)
    per_label = {label: per_label_correct[label] / total for label, total in sorted(per_label_total.items())}
    predictions = [
        {
            "text": row["text"],
            "label": labels[want_id],
            "prediction": labels[got_id],
            "confidence": confidence,
            "correct": want_id == got_id,
        }
        for row, want_id, got_id, confidence in zip(rows, expected_ids, predicted_ids, confidences)
    ]
    return accuracy, per_label, pairs, predictions


def write_predictions(path: Path, predictions: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for prediction in predictions:
            handle.write(json.dumps(prediction, ensure_ascii=False) + "\n")
    print(f"predictions: {path}")


def apply_config_overrides(config, arguments: Arguments) -> None:
    overrides = {
        "classifier_dropout": arguments.classifier_dropout,
        "attention_dropout": arguments.attention_dropout,
        "embedding_dropout": arguments.embedding_dropout,
        "mlp_dropout": arguments.mlp_dropout,
        "classifier_pooling": arguments.classifier_pooling,
    }
    for name, value in overrides.items():
        if value is None:
            continue
        if not hasattr(config, name):
            raise SystemExit(f"error: backbone config has no field {name}")
        setattr(config, name, value)


def freeze_encoder(model) -> None:
    encoder = getattr(model, "model", None)
    if encoder is None:
        raise SystemExit("error: --freeze-encoder could not find model.model")
    for parameter in encoder.parameters():
        parameter.requires_grad = False
    trainable = sum(parameter.numel() for parameter in model.parameters() if parameter.requires_grad)
    frozen = sum(parameter.numel() for parameter in model.parameters() if not parameter.requires_grad)
    print(f"encoder frozen: {trainable:,} trainable parameters, {frozen:,} frozen")


def truncate_modernbert_layers(model, keep: int) -> None:
    import torch

    if keep <= 0:
        return
    layers = getattr(getattr(model, "model", None), "layers", None)
    if layers is None:
        raise SystemExit("error: --truncate-layers is only implemented for ModernBERT-style models")
    if keep >= len(layers):
        return
    model.model.layers = torch.nn.ModuleList(list(layers)[:keep])
    model.config.num_hidden_layers = keep
    model.model.config.num_hidden_layers = keep
    print(f"transformer truncated to {keep} layers")


def patch_modernbert_for_coreml_export(model, seq_len: int) -> None:
    """Avoids TorchScript/Core ML conversion bugs in dynamic ModernBERT RoPE.

    Core ML Tools currently fails on the `x.shape[-1] // 2` path used by
    ModernBERT's `rotate_half`. For the app we always export a fixed sequence
    length, so we precompute RoPE cos/sin tensors and use constant dimensions.
    """
    import torch

    if getattr(model.config, "model_type", "") != "modernbert":
        return
    model.config._attn_implementation = "eager"
    positions = torch.arange(seq_len, dtype=torch.float32)
    for layer in model.model.layers:
        attention = layer.attn
        attention.config._attn_implementation = "eager"
        inv_freq = attention.rotary_emb.inv_freq.detach().float()
        freqs = torch.outer(positions, inv_freq)
        emb = torch.cat((freqs, freqs), dim=-1)
        scale = float(getattr(attention.rotary_emb, "attention_scaling", 1.0))
        attention.register_buffer(
            "_export_cos",
            (emb.cos() * scale).view(1, 1, seq_len, attention.head_dim),
            persistent=False,
        )
        attention.register_buffer(
            "_export_sin",
            (emb.sin() * scale).view(1, 1, seq_len, attention.head_dim),
            persistent=False,
        )

        def fixed_forward(self, hidden_states, output_attentions=False, **kwargs):
            qkv = self.Wqkv(hidden_states)
            qkv = qkv.view(1, seq_len, 3, self.num_heads, self.head_dim)
            query, key, value = qkv.transpose(3, 1).unbind(dim=2)
            cos = self._export_cos.to(dtype=query.dtype)
            sin = self._export_sin.to(dtype=query.dtype)
            half = self.head_dim // 2
            query_rotated = torch.cat((-query[..., half:], query[..., :half]), dim=-1)
            key_rotated = torch.cat((-key[..., half:], key[..., :half]), dim=-1)
            query = (query * cos) + (query_rotated * sin)
            key = (key * cos) + (key_rotated * sin)
            attention_mask = kwargs.get("attention_mask")
            if self.local_attention != (-1, -1):
                attention_mask = kwargs.get("sliding_window_mask")
            weights = torch.matmul(query, key.transpose(2, 3)) * (self.head_dim**-0.5)
            if attention_mask is not None:
                weights = weights + attention_mask
            weights = torch.nn.functional.softmax(weights, dim=-1, dtype=torch.float32).to(query.dtype)
            output = torch.matmul(weights, value)
            output = output.transpose(1, 2).contiguous().view(1, seq_len, self.all_head_size)
            output = self.out_drop(self.Wo(output))
            return (output, weights) if output_attentions else (output,)

        attention.forward = types.MethodType(fixed_forward, attention)


def export_coreml(model, labels: list[str], max_length: int, quantize: str):
    import coremltools as ct
    import numpy as np
    import torch

    class FusedClassifier(torch.nn.Module):
        def __init__(self, classifier):
            super().__init__()
            self.classifier = classifier.to("cpu").eval()

        def forward(self, input_ids, attention_mask):
            outputs = self.classifier(
                input_ids=input_ids.to(torch.long),
                attention_mask=attention_mask.to(torch.long),
                return_dict=True,
            )
            return torch.softmax(outputs.logits, dim=-1)

    model.to("cpu").eval()
    patch_modernbert_for_coreml_export(model, max_length)
    fused = FusedClassifier(model).eval()
    example_ids = torch.ones((1, max_length), dtype=torch.int32)
    example_mask = torch.ones((1, max_length), dtype=torch.int32)
    traced = torch.jit.trace(fused, (example_ids, example_mask))
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name=MODEL_INPUT_IDS, shape=(1, max_length), dtype=np.int32),
            ct.TensorType(name=MODEL_ATTENTION_MASK, shape=(1, max_length), dtype=np.int32),
        ],
        classifier_config=ct.ClassifierConfig(class_labels=labels),
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
    )
    if quantize == "int8":
        from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

        config = OptimizationConfig(
            global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
        )
        mlmodel = linear_quantize_weights(mlmodel, config=config)
    return mlmodel


def directory_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    for file in sorted(path.rglob("*")):
        if file.is_file():
            digest.update(str(file.relative_to(path)).encode("utf-8"))
            digest.update(file.read_bytes())
    return digest.hexdigest()


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def remote_artifacts(paths: list[Path], root: Path) -> list[dict]:
    artifacts: list[dict] = []
    for path in paths:
        files = sorted(item for item in path.rglob("*") if item.is_file()) if path.is_dir() else [path]
        for file in files:
            artifacts.append(
                {
                    "path": file.relative_to(root).as_posix(),
                    "sha256": file_sha256(file),
                    "byteCount": file.stat().st_size,
                }
            )
    return sorted(artifacts, key=lambda item: item["path"])


def write_tokenizer_artifact(tokenizer, out_dir: Path, model_name: str) -> Path:
    artifact = out_dir / f"{model_name}.tokenizer.json"
    with tempfile.TemporaryDirectory() as temp:
        temp_dir = Path(temp)
        tokenizer.save_pretrained(temp_dir)
        shutil.copy2(temp_dir / "tokenizer.json", artifact)
    return artifact


def write_training_report(
    out_dir: Path,
    arguments: Arguments,
    accuracy: float,
    per_label: dict[str, float],
    pairs: list[tuple[str, str]],
    loss_points: list[dict],
    label_counts: Counter,
) -> Path:
    metrics_path = out_dir / "metrics.jsonl"
    with metrics_path.open("w", encoding="utf-8") as handle:
        for point in loss_points:
            handle.write(json.dumps({"kind": "loss", **point}) + "\n")
        handle.write(json.dumps({"kind": "validation", "accuracy": accuracy, "perLabel": per_label}) + "\n")

    confusion: Counter = Counter((want, got) for want, got in pairs if want != got)
    confusion_rows = "".join(
        f'<tr><td class="mono">{want}</td><td class="mono">{got}</td><td class="mono">{count}</td></tr>'
        for (want, got), count in confusion.most_common(15)
    ) or '<tr><td colspan="3">No validation confusions</td></tr>'
    loss_rows = "".join(
        f'<tr><td class="mono">{point["step"]}</td><td class="mono">{point["epoch"]}</td><td class="mono">{point["loss"]:.4f}</td></tr>'
        for point in loss_points
    ) or '<tr><td colspan="3">Training skipped or no loss logged.</td></tr>'
    accuracy_rows = "".join(
        f'<tr><td class="mono">{label}</td><td class="mono">{score * 100:.1f}%</td><td class="mono">{label_counts.get(label, 0)}</td></tr>'
        for label, score in sorted(per_label.items(), key=lambda item: item[1])
    )
    html = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Sift mmBERT training report</title>
<style>
body{{font:14px/1.5 -apple-system,system-ui,sans-serif;margin:32px auto;max-width:820px;color:#222}}
h1{{font-size:20px}} h2{{font-size:15px;margin-top:28px}}
table{{border-collapse:collapse;width:100%}} td,th{{padding:3px 8px;border-bottom:1px solid #eee;text-align:left;font-size:12px}}
.mono{{font-family:ui-monospace,monospace}}
.kpi{{display:inline-block;margin-right:24px;padding:10px 14px;background:#f4f6f5;border-radius:8px}}
.kpi b{{display:block;font-size:20px}}
</style></head><body>
<h1>Sift mmBERT training report</h1>
<p class="mono">version {arguments.version} · backbone {arguments.backbone} · corpus {arguments.input.name}</p>
<div>
  <span class="kpi"><b>{accuracy * 100:.2f}%</b>validation accuracy</span>
  <span class="kpi"><b>{sum(label_counts.values())}</b>training rows</span>
  <span class="kpi"><b>{len(label_counts)}</b>labels</span>
</div>
<h2>Loss logs</h2>
<table><tr><th>step</th><th>epoch</th><th>loss</th></tr>{loss_rows}</table>
<h2>Per-label validation accuracy (worst first)</h2>
<table><tr><th>label</th><th>accuracy</th><th>train rows</th></tr>{accuracy_rows}</table>
<h2>Top validation confusions</h2>
<table><tr><th>expected</th><th>predicted</th><th>count</th></tr>{confusion_rows}</table>
</body></html>
"""
    report_path = out_dir / "training-report.html"
    report_path.write_text(html, encoding="utf-8")
    return report_path


def tokenizer_kind(tokenizer) -> str:
    backend = getattr(tokenizer, "backend_tokenizer", None)
    if backend is None:
        return "unknown"
    return type(backend.model).__name__.lower()


def main() -> None:
    arguments = parse_arguments()
    repo_root = locate_repo_root()

    rows = load_rows(arguments.input, max_rows=arguments.max_rows)
    valid_labels = load_taxonomy_labels(repo_root)
    unknown = {row["label"] for row in rows} - valid_labels
    if unknown:
        raise SystemExit(f"error: unknown labels in dataset: {', '.join(sorted(unknown))}")

    labels = sorted({row["label"] for row in rows})
    label_to_id = {label: index for index, label in enumerate(labels)}
    id_to_label = {index: label for label, index in label_to_id.items()}
    training_rows, validation_rows = stratified_split(rows, arguments.validation_fraction, arguments.seed)
    print(f"rows: {len(rows)} total, {len(training_rows)} train, {len(validation_rows)} validation, {len(labels)} labels")

    import torch
    from transformers import AutoConfig, AutoModelForSequenceClassification, AutoTokenizer, set_seed

    set_seed(arguments.seed)
    device = select_device(arguments.device)
    print(f"device: {describe_device(device)}")

    model_source = str(arguments.resume_from) if arguments.resume_from is not None else arguments.backbone
    tokenizer_source = model_source
    tokenizer = AutoTokenizer.from_pretrained(tokenizer_source)
    config = AutoConfig.from_pretrained(
        model_source,
        num_labels=len(labels),
        id2label=id_to_label,
        label2id=label_to_id,
    )
    apply_config_overrides(config, arguments)
    model = AutoModelForSequenceClassification.from_pretrained(
        model_source,
        config=config,
        ignore_mismatched_sizes=True,
    )
    model.config.problem_type = "single_label_classification"
    truncate_modernbert_layers(model, arguments.truncate_layers)
    if arguments.freeze_encoder:
        freeze_encoder(model)

    losses = train_model(model, tokenizer, training_rows, label_to_id, arguments, device)
    accuracy, per_label, prediction_pairs, validation_predictions = evaluate_model(
        model,
        tokenizer,
        validation_rows,
        label_to_id,
        labels,
        arguments.max_length,
        device,
    )
    print(f"validation accuracy: {accuracy:.4f}")
    for label, score in per_label.items():
        print(f"  {label}: {score:.3f}")

    test_accuracy: float | None = None
    test_per_label: dict[str, float] = {}
    test_prediction_pairs: list[tuple[str, str]] = []
    test_predictions: list[dict] = []
    test_rows: list[dict[str, str]] = []
    if arguments.test_input is not None:
        test_rows = load_rows(arguments.test_input)
        test_unknown = {row["label"] for row in test_rows} - set(label_to_id)
        if test_unknown:
            raise SystemExit(f"error: labels in --test-input are absent from training data: {', '.join(sorted(test_unknown))}")
        test_accuracy, test_per_label, test_prediction_pairs, test_predictions = evaluate_model(
            model,
            tokenizer,
            test_rows,
            label_to_id,
            labels,
            arguments.max_length,
            device,
        )
        print(f"test accuracy: {test_accuracy:.4f}")
        for label, score in test_per_label.items():
            print(f"  test {label}: {score:.3f}")

    out = arguments.out
    out.mkdir(parents=True, exist_ok=True)
    if arguments.write_predictions is not None:
        write_predictions(
            arguments.write_predictions,
            test_predictions if arguments.test_input is not None else validation_predictions,
        )

    if arguments.save_checkpoint != "off":
        checkpoint_dir = out / "checkpoint" if arguments.save_checkpoint == "auto" else Path(arguments.save_checkpoint).expanduser().resolve()
        checkpoint_dir.mkdir(parents=True, exist_ok=True)
        model.save_pretrained(checkpoint_dir)
        tokenizer.save_pretrained(checkpoint_dir)
        print(f"checkpoint: {checkpoint_dir}")

    if arguments.skip_export:
        write_training_report(
            out,
            arguments,
            accuracy,
            per_label,
            prediction_pairs,
            losses,
            Counter(row["label"] for row in training_rows),
        )
        summary = {
            "version": arguments.version,
            "trainedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
            "algorithm": "supervised-sequence-classification",
            "backbone": arguments.backbone,
            "validationAccuracy": accuracy,
            "validationCount": len(validation_rows),
            "testAccuracy": test_accuracy,
            "testCount": len(test_rows),
            "trainingCount": len(training_rows),
            "hyperparameters": {
                "numEpochs": arguments.num_epochs,
                "batchSize": arguments.batch_size,
                "learningRate": arguments.learning_rate,
                "weightDecay": arguments.weight_decay,
                "warmupRatio": arguments.warmup_ratio,
                "labelSmoothing": arguments.label_smoothing,
                "classifierDropout": arguments.classifier_dropout,
                "attentionDropout": arguments.attention_dropout,
                "embeddingDropout": arguments.embedding_dropout,
                "mlpDropout": arguments.mlp_dropout,
                "classifierPooling": arguments.classifier_pooling,
                "freezeEncoder": arguments.freeze_encoder,
                "maxLength": arguments.max_length,
                "seed": arguments.seed,
            },
            "labels": labels,
        }
        summary_path = out / "tuning-summary.json"
        summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"summary: {summary_path}")
        print("export skipped")
        return

    package_path = out / f"{arguments.model_name}.mlpackage"
    if package_path.exists():
        shutil.rmtree(package_path)
    mlmodel = export_coreml(model, labels, arguments.max_length, arguments.quantize)
    mlmodel.save(str(package_path))

    tokenizer_path = write_tokenizer_artifact(tokenizer, out, arguments.model_name)
    downloadable_artifacts = remote_artifacts([package_path, tokenizer_path], out)
    manifest = {
        "version": arguments.version,
        "trainedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
        "algorithm": "supervised-sequence-classification",
        "backbone": arguments.backbone,
        "languages": arguments.languages,
        "labels": labels,
        "maxSequenceLength": arguments.max_length,
        "doLowerCase": bool(getattr(tokenizer, "do_lower_case", False)),
        "tokenizerKind": tokenizer_kind(tokenizer),
        "tokenizerArtifact": tokenizer_path.name,
        "modelArtifact": package_path.name,
        "sha256": directory_sha256(package_path),
        "taxonomyHash": file_sha256(repo_root / "packages/taxonomy/taxonomy.json"),
        "remoteArtifacts": downloadable_artifacts,
        "downloadBytes": sum(item["byteCount"] for item in downloadable_artifacts),
        "validationAccuracy": accuracy,
        "trainingCount": len(training_rows),
        "validationCount": len(validation_rows),
    }
    if test_accuracy is not None:
        manifest["testAccuracy"] = test_accuracy
        manifest["testCount"] = len(test_rows)
    manifest_path = out / f"{arguments.model_name}.manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    report_path = write_training_report(
        out,
        arguments,
        accuracy,
        per_label,
        prediction_pairs,
        losses,
        Counter(row["label"] for row in training_rows),
    )

    print(f"model: {package_path}")
    print(f"tokenizer: {tokenizer_path}")
    print(f"manifest: {manifest_path}")
    print(f"report: {report_path}")

    if arguments.install_ios:
        generated = repo_root / "apps/ios/GeneratedModels"
        generated.mkdir(parents=True, exist_ok=True)
        installed_package = generated / package_path.name
        if installed_package.exists():
            shutil.rmtree(installed_package)
        shutil.copytree(package_path, installed_package)
        shutil.copy2(tokenizer_path, generated / tokenizer_path.name)
        shutil.copy2(manifest_path, generated / manifest_path.name)
        print(f"installed: {generated}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
