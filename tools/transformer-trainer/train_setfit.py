#!/usr/bin/env python3
"""Train a multilingual SetFit SMS classifier and export it as a frozen Core ML model.

The exported artifact set is what `apps/ios` consumes for the non-fine-tunable
"Transformer" model variant:

  SiftTransformerClassifier.mlpackage      fused body + head Core ML classifier
  SiftTransformerClassifier.vocab.txt      WordPiece vocabulary (one token/line)
  SiftTransformerClassifier.manifest.json  metadata read by TransformerClassifierLoader

The Core ML model takes `input_ids` / `attention_mask` int32 tensors of shape
[1, max_length] produced by the Swift `WordPieceTokenizer`, and emits a
predicted label plus a per-label probability dictionary.

Only WordPiece-vocabulary backbones are supported because the on-device
tokenizer is WordPiece (e.g. `sentence-transformers/distiluse-base-multilingual-cased-v2`
or other mBERT/DistilmBERT-family models). SentencePiece backbones are
rejected with an explicit error.

Usage:
    uv run train_setfit.py --input ../../build/public-corpus.ndjson \
        --out ../../build/transformer-model --install-ios
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import shutil
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

# Must be set before torch dispatches any MPS op: lets Apple-Silicon runs fall
# back to CPU for the few ops MPS still lacks instead of crashing.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

MODEL_INPUT_IDS = "input_ids"
MODEL_ATTENTION_MASK = "attention_mask"
DEFAULT_BACKBONE = "sentence-transformers/distiluse-base-multilingual-cased-v2"


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
    body_samples_per_label: int
    num_iterations: int
    num_epochs: int
    batch_size: int
    body_learning_rate: float | None
    head_only: bool
    truncate_layers: int
    prune_vocab: bool
    quantize: str
    device: str
    resume_from: Path | None
    save_checkpoint: str
    install_ios: bool
    seed: int


def parse_arguments() -> Arguments:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=Path, required=True, help="text/label NDJSON corpus")
    parser.add_argument("--out", type=Path, default=None, help="output directory (default build/transformer-model)")
    parser.add_argument("--backbone", default=DEFAULT_BACKBONE, help="WordPiece sentence-transformer backbone")
    parser.add_argument("--model-name", default="SiftTransformerClassifier")
    parser.add_argument("--version", default="setfit-0.1")
    parser.add_argument(
        "--languages",
        default="zh,en,es,pt,fr,de,ru,ja,ko,id,vi,th",
        help="comma-separated language tags recorded in the manifest",
    )
    parser.add_argument("--max-length", type=int, default=96, help="token sequence length (SMS fits in 96)")
    parser.add_argument("--validation-fraction", type=float, default=0.1)
    parser.add_argument(
        "--body-samples-per-label",
        type=int,
        default=32,
        help="rows per label fed to the contrastive body-training phase",
    )
    parser.add_argument("--num-iterations", type=int, default=10, help="SetFit contrastive pair iterations")
    parser.add_argument("--num-epochs", type=int, default=1)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument(
        "--body-learning-rate",
        type=float,
        default=None,
        help="contrastive-phase learning rate (use a small value like 1e-5 when fine-tuning from a checkpoint)",
    )
    parser.add_argument("--head-only", action="store_true", help="skip contrastive body training (fast smoke run)")
    parser.add_argument(
        "--truncate-layers",
        type=int,
        default=0,
        help="keep only the first N transformer layers before training (0 = keep all)",
    )
    parser.add_argument(
        "--prune-vocab",
        action="store_true",
        help="prune the embedding matrix to tokens observed in the corpus (plus single-character fallbacks)",
    )
    parser.add_argument("--quantize", choices=["fp16", "int8"], default="fp16")
    parser.add_argument(
        "--device",
        choices=["auto", "cpu", "cuda", "mps"],
        default="auto",
        help="training device. auto picks cuda (NVIDIA CUDA or AMD ROCm torch builds), "
        "then mps (Apple Silicon), then cpu. Export always runs on cpu.",
    )
    parser.add_argument(
        "--resume-from",
        type=Path,
        default=None,
        help="resume from a checkpoint directory produced by --save-checkpoint "
        "(continues contrastive training and refits the head)",
    )
    parser.add_argument(
        "--save-checkpoint",
        default="auto",
        help="checkpoint directory; 'auto' = <out>/checkpoint, 'off' disables saving",
    )
    parser.add_argument("--install-ios", action="store_true", help="copy artifacts into apps/ios/GeneratedModels")
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
        body_samples_per_label=raw.body_samples_per_label,
        num_iterations=raw.num_iterations,
        num_epochs=raw.num_epochs,
        batch_size=raw.batch_size,
        body_learning_rate=raw.body_learning_rate,
        head_only=raw.head_only,
        truncate_layers=raw.truncate_layers,
        prune_vocab=raw.prune_vocab,
        quantize=raw.quantize,
        device=raw.device,
        resume_from=(raw.resume_from.expanduser().resolve() if raw.resume_from else None),
        save_checkpoint=raw.save_checkpoint,
        install_ios=raw.install_ios,
        seed=raw.seed,
    )


def locate_repo_root() -> Path:
    directory = Path(__file__).resolve().parent
    while directory != directory.parent:
        if (directory / "packages/taxonomy/taxonomy.json").exists():
            return directory
        directory = directory.parent
    raise SystemExit("error: could not locate repo root containing packages/taxonomy/taxonomy.json")


def load_rows(path: Path) -> list[dict[str, str]]:
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


def subsample_per_label(rows: list[dict[str, str]], per_label: int, seed: int) -> list[dict[str, str]]:
    rng = random.Random(seed)
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        grouped[row["label"]].append(row)
    sampled: list[dict[str, str]] = []
    for label in sorted(grouped):
        bucket = grouped[label][:]
        rng.shuffle(bucket)
        sampled.extend(bucket[:per_label])
    rng.shuffle(sampled)
    return sampled


def require_wordpiece(tokenizer) -> None:
    backend = getattr(tokenizer, "backend_tokenizer", None)
    model_type = type(backend.model).__name__ if backend is not None else ""
    if model_type != "WordPiece":
        raise SystemExit(
            f"error: backbone tokenizer is {model_type or 'unknown'}, but the on-device tokenizer "
            "only supports WordPiece vocabularies. Pick an mBERT/DistilmBERT-family backbone such as "
            f"{DEFAULT_BACKBONE}."
        )


def select_device(requested: str) -> str:
    """Resolves the training device.

    `auto` prefers `cuda` — which is also what AMD ROCm builds of PyTorch
    report (`torch.version.hip` is set and `torch.cuda.is_available()` is
    True) — then Apple-Silicon `mps`, then `cpu`. Core ML export always runs
    on CPU regardless of the training device.
    """
    import torch

    cuda_available = torch.cuda.is_available()
    mps_available = bool(getattr(torch.backends, "mps", None)) and torch.backends.mps.is_available()

    if requested == "cuda" and not cuda_available:
        raise SystemExit(
            "error: --device cuda requested but torch.cuda.is_available() is False. "
            "For AMD GPUs install a ROCm build of torch (see README); for NVIDIA check drivers."
        )
    if requested == "mps" and not mps_available:
        raise SystemExit(
            "error: --device mps requested but MPS is unavailable. Requires Apple Silicon, "
            "macOS 12.3+, and an arm64 Python/torch build."
        )

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
        name = torch.cuda.get_device_name(0) if torch.cuda.device_count() > 0 else "unknown GPU"
        if getattr(torch.version, "hip", None):
            return f"cuda ({name}, AMD ROCm/HIP {torch.version.hip})"
        return f"cuda ({name}, CUDA {torch.version.cuda})"
    if device == "mps":
        return "mps (Apple Silicon GPU via Metal)"
    return "cpu"


def make_training_arguments(**kwargs):
    """Builds setfit TrainingArguments with only the kwargs this setfit
    version supports, so minor API drift doesn't break the script."""
    import inspect

    from setfit import TrainingArguments

    supported = inspect.signature(TrainingArguments.__init__).parameters
    filtered = {key: value for key, value in kwargs.items() if key in supported and value is not None}
    dropped = sorted(set(kwargs) - set(filtered))
    if dropped:
        print(f"note: this setfit version ignores training args: {', '.join(dropped)}")
    return TrainingArguments(**filtered)


def truncate_transformer_layers(auto_model, keep: int) -> None:
    """Keeps the first `keep` encoder layers; a cheap width-preserving shrink."""
    import torch

    for path in ("transformer.layer", "encoder.layer"):
        node = auto_model
        found = True
        for part in path.split("."):
            if not hasattr(node, part):
                found = False
                break
            node = getattr(node, part)
        if found:
            parent = auto_model
            parts = path.split(".")
            for part in parts[:-1]:
                parent = getattr(parent, part)
            setattr(parent, parts[-1], torch.nn.ModuleList(list(node)[:keep]))
            auto_model.config.num_hidden_layers = keep
            if hasattr(auto_model.config, "n_layers"):
                auto_model.config.n_layers = keep
            return
    raise SystemExit("error: --truncate-layers is not supported for this backbone architecture")


def prune_vocabulary(model_body, texts: list[str]) -> list[str]:
    """Prunes the embedding matrix to corpus tokens plus robust fallbacks.

    Keeps: special tokens, every token actually produced on the corpus, and
    all length-1 tokens (plus their `##` continuations) so unseen words still
    decompose instead of collapsing to [UNK]. Returns the new vocab in id
    order and remaps the embedding matrix in place.
    """
    import torch

    tokenizer = model_body.tokenizer
    auto_model = model_body[0].auto_model
    vocab: dict[str, int] = tokenizer.get_vocab()

    keep_ids: set[int] = set(tokenizer.all_special_ids)
    for token, token_id in vocab.items():
        stripped = token[2:] if token.startswith("##") else token
        if len(stripped) == 1:
            keep_ids.add(token_id)

    batch = 512
    for start in range(0, len(texts), batch):
        encoded = tokenizer(texts[start : start + batch], add_special_tokens=True)
        for ids in encoded["input_ids"]:
            keep_ids.update(ids)

    ordered_ids = sorted(keep_ids)
    id_to_token = {token_id: token for token, token_id in vocab.items()}
    new_tokens = [id_to_token[token_id] for token_id in ordered_ids]

    old_embeddings = auto_model.get_input_embeddings()
    index = torch.tensor(ordered_ids, dtype=torch.long)
    new_embeddings = torch.nn.Embedding(len(ordered_ids), old_embeddings.weight.shape[1])
    with torch.no_grad():
        new_embeddings.weight.copy_(old_embeddings.weight[index])
    auto_model.set_input_embeddings(new_embeddings)
    auto_model.config.vocab_size = len(ordered_ids)

    pad_token = tokenizer.pad_token or "[PAD]"
    auto_model.config.pad_token_id = new_tokens.index(pad_token)
    print(f"vocabulary pruned: {len(vocab)} -> {len(new_tokens)} tokens")
    return new_tokens


def vocabulary_tokens(tokenizer) -> list[str]:
    vocab = tokenizer.get_vocab()
    return [token for token, _ in sorted(vocab.items(), key=lambda item: item[1])]


def build_fused_module(model, labels: list[str]):
    """Fuses sentence-transformer body + classification head into one module.

    The body is moved to CPU first: `torch.jit.trace` inputs and coremltools
    conversion both run on CPU, so a body left on cuda/mps would fail with a
    device mismatch.
    """
    import numpy as np
    import torch

    body = model.model_body.to("cpu").eval()
    head = model.model_head
    embedding_dim = body.get_sentence_embedding_dimension()

    linear = torch.nn.Linear(embedding_dim, len(labels))
    if hasattr(head, "coef_"):
        coef = np.asarray(head.coef_, dtype=np.float32)
        intercept = np.asarray(head.intercept_, dtype=np.float32)
        if coef.shape[0] == 1 and len(labels) == 2:
            # sklearn binary convention: single row of logits for class 1.
            coef = np.vstack([-coef[0], coef[0]])
            intercept = np.array([-intercept[0], intercept[0]], dtype=np.float32)
        with torch.no_grad():
            linear.weight.copy_(torch.from_numpy(coef))
            linear.bias.copy_(torch.from_numpy(intercept))
        head_classes = [str(item) for item in head.classes_]
    else:
        # Differentiable torch head (SetFitHead): reuse its linear weights.
        torch_linear = head.linear if hasattr(head, "linear") else head
        with torch.no_grad():
            linear.weight.copy_(torch_linear.weight)
            linear.bias.copy_(torch_linear.bias)
        head_classes = labels

    if head_classes != labels:
        raise SystemExit(f"error: head class order {head_classes} does not match label order {labels}")

    class FusedClassifier(torch.nn.Module):
        def __init__(self, sentence_transformer, classifier_head):
            super().__init__()
            self.sentence_transformer = sentence_transformer
            self.classifier_head = classifier_head

        def forward(self, input_ids, attention_mask):
            features = {
                MODEL_INPUT_IDS: input_ids.to(torch.long),
                MODEL_ATTENTION_MASK: attention_mask.to(torch.long),
            }
            embedding = self.sentence_transformer(features)["sentence_embedding"]
            return torch.softmax(self.classifier_head(embedding), dim=-1)

    return FusedClassifier(body, linear).eval()


def export_coreml(fused, labels: list[str], max_length: int, quantize: str):
    import coremltools as ct
    import numpy as np
    import torch

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



def make_loss_recorder():
    """TrainerCallback capturing per-step losses; None when the installed
    setfit/transformers combination doesn't expose the callback API."""
    try:
        from transformers.trainer_callback import TrainerCallback
    except ImportError:
        return None

    class LossRecorder(TrainerCallback):
        def __init__(self) -> None:
            self.points: list[dict] = []

        def on_log(self, args, state, control, logs=None, **kwargs):
            if not logs:
                return
            loss = logs.get("embedding_loss", logs.get("loss"))
            if loss is not None:
                self.points.append({"step": state.global_step, "loss": float(loss)})

    return LossRecorder()


def loss_curve_svg(points: list[dict], width: int = 640, height: int = 200) -> str:
    if len(points) < 2:
        return "<p>No loss curve recorded (head-only run or callback unsupported).</p>"
    losses = [point["loss"] for point in points]
    low, high = min(losses), max(losses)
    span = (high - low) or 1.0
    pad = 24
    step_x = (width - 2 * pad) / (len(points) - 1)
    coordinates = " ".join(
        f"{pad + index * step_x:.1f},{height - pad - (point['loss'] - low) / span * (height - 2 * pad):.1f}"
        for index, point in enumerate(points)
    )
    return (
        f'<svg viewBox="0 0 {width} {height}" role="img" style="width:100%;max-width:{width}px">'
        f'<rect width="{width}" height="{height}" fill="#fafafa" stroke="#ddd"/>'
        f'<polyline fill="none" stroke="#0a7" stroke-width="2" points="{coordinates}"/>'
        f'<text x="{pad}" y="16" font-size="11" fill="#555">embedding loss (min {low:.4f}, max {high:.4f}, {len(points)} logs)</text>'
        "</svg>"
    )


def write_training_report(
    out_dir: Path,
    arguments: "Arguments",
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
    top_confusions = confusion.most_common(15)

    def bar_rows() -> str:
        rows = []
        for label, score in sorted(per_label.items(), key=lambda item: item[1]):
            percent = f"{score * 100:.1f}"
            color = "#0a7" if score >= 0.9 else ("#e8a13a" if score >= 0.7 else "#d9534f")
            rows.append(
                f'<tr><td class="mono">{label}</td>'
                f'<td class="bar"><div style="width:{percent}%;background:{color}"></div></td>'
                f'<td class="mono">{percent}%</td>'
                f'<td class="mono">{label_counts.get(label, 0)}</td></tr>'
            )
        return "".join(rows)

    confusion_rows = "".join(
        f'<tr><td class="mono">{want}</td><td class="mono">{got}</td><td class="mono">{count}</td></tr>'
        for (want, got), count in top_confusions
    ) or '<tr><td colspan="3">No validation confusions 🎉</td></tr>'

    html = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Sift transformer training report</title>
<style>
body{{font:14px/1.5 -apple-system,system-ui,sans-serif;margin:32px auto;max-width:760px;color:#222}}
h1{{font-size:20px}} h2{{font-size:15px;margin-top:28px}}
table{{border-collapse:collapse;width:100%}} td,th{{padding:3px 8px;border-bottom:1px solid #eee;text-align:left;font-size:12px}}
.mono{{font-family:ui-monospace,monospace}}
.bar{{width:45%}} .bar div{{height:10px;border-radius:3px}}
.kpi{{display:inline-block;margin-right:24px;padding:10px 14px;background:#f4f6f5;border-radius:8px}}
.kpi b{{display:block;font-size:20px}}
</style></head><body>
<h1>Sift transformer training report</h1>
<p class="mono">version {arguments.version} · backbone {arguments.backbone} · device-trained corpus {arguments.input.name}</p>
<div>
  <span class="kpi"><b>{accuracy * 100:.2f}%</b>validation accuracy</span>
  <span class="kpi"><b>{sum(label_counts.values())}</b>training rows</span>
  <span class="kpi"><b>{len(label_counts)}</b>labels</span>
</div>
<h2>Embedding loss</h2>
{loss_curve_svg(loss_points)}
<h2>Per-label validation accuracy (worst first)</h2>
<table><tr><th>label</th><th>accuracy</th><th></th><th>train rows</th></tr>{bar_rows()}</table>
<h2>Top validation confusions (expected → predicted)</h2>
<table><tr><th>expected</th><th>predicted</th><th>count</th></tr>{confusion_rows}</table>
</body></html>
"""
    report_path = out_dir / "training-report.html"
    report_path.write_text(html, encoding="utf-8")
    return report_path


def evaluate(model, rows: list[dict[str, str]]) -> tuple[float, dict[str, float], list[tuple[str, str]]]:
    """Returns (accuracy, per-label accuracy, [(expected, predicted)] pairs)."""
    if not rows:
        return 0.0, {}, []
    texts = [row["text"] for row in rows]
    expected = [row["label"] for row in rows]
    predictions = [str(item) for item in model.predict(texts)]
    per_label_total: Counter[str] = Counter(expected)
    per_label_correct: Counter[str] = Counter()
    for want, got in zip(expected, predictions):
        if want == got:
            per_label_correct[want] += 1
    accuracy = sum(per_label_correct.values()) / len(rows)
    per_label = {label: per_label_correct[label] / total for label, total in sorted(per_label_total.items())}
    return accuracy, per_label, list(zip(expected, predictions))


def main() -> None:
    arguments = parse_arguments()
    repo_root = locate_repo_root()

    rows = load_rows(arguments.input)
    valid_labels = load_taxonomy_labels(repo_root)
    unknown = {row["label"] for row in rows} - valid_labels
    if unknown:
        raise SystemExit(f"error: unknown labels in dataset: {', '.join(sorted(unknown))}")

    labels = sorted({row["label"] for row in rows})
    training_rows, validation_rows = stratified_split(rows, arguments.validation_fraction, arguments.seed)
    print(f"rows: {len(rows)} total, {len(training_rows)} train, {len(validation_rows)} validation, {len(labels)} labels")

    import torch
    from datasets import Dataset
    from setfit import SetFitModel, Trainer

    torch.manual_seed(arguments.seed)
    device = select_device(arguments.device)
    print(f"device: {describe_device(device)}")

    if arguments.resume_from is not None:
        if not arguments.resume_from.exists():
            raise SystemExit(f"error: --resume-from checkpoint not found: {arguments.resume_from}")
        print(f"resuming from checkpoint: {arguments.resume_from}")
        model = SetFitModel.from_pretrained(str(arguments.resume_from), labels=labels)
    else:
        model = SetFitModel.from_pretrained(arguments.backbone, labels=labels)
    tokenizer = model.model_body.tokenizer
    require_wordpiece(tokenizer)
    model.model_body.max_seq_length = arguments.max_length

    if arguments.truncate_layers > 0:
        truncate_transformer_layers(model.model_body[0].auto_model, arguments.truncate_layers)
        print(f"transformer truncated to {arguments.truncate_layers} layers")

    model.to(device)

    loss_recorder = make_loss_recorder()
    if not arguments.head_only:
        import inspect

        body_rows = subsample_per_label(training_rows, arguments.body_samples_per_label, arguments.seed)
        body_dataset = Dataset.from_dict(
            {"text": [row["text"] for row in body_rows], "label": [row["label"] for row in body_rows]}
        )
        trainer_kwargs = dict(
            model=model,
            train_dataset=body_dataset,
            args=make_training_arguments(
                batch_size=arguments.batch_size,
                num_epochs=arguments.num_epochs,
                num_iterations=arguments.num_iterations,
                body_learning_rate=arguments.body_learning_rate,
                seed=arguments.seed,
            ),
        )
        if loss_recorder is not None and "callbacks" in inspect.signature(Trainer.__init__).parameters:
            trainer_kwargs["callbacks"] = [loss_recorder]
        trainer = Trainer(**trainer_kwargs)
        trainer.train()

    # The classification head always trains on the full corpus embeddings.
    model.fit(
        [row["text"] for row in training_rows],
        [row["label"] for row in training_rows],
        num_epochs=1,
    )

    accuracy, per_label, prediction_pairs = evaluate(model, validation_rows)
    print(f"validation accuracy: {accuracy:.4f}")
    for label, score in per_label.items():
        print(f"  {label}: {score:.3f}")

    # Everything from here on (vocab pruning, fusing, tracing, Core ML
    # conversion) is CPU-only; leaving the body on cuda/mps would make
    # torch.jit.trace fail with a device mismatch.
    model.model_body.to("cpu")

    if arguments.save_checkpoint != "off":
        checkpoint_dir = (
            arguments.out / "checkpoint"
            if arguments.save_checkpoint == "auto"
            else Path(arguments.save_checkpoint).expanduser().resolve()
        )
        # Saved before vocab pruning so resumed runs start from the full
        # vocabulary; pruning is an export-only transform.
        checkpoint_dir.mkdir(parents=True, exist_ok=True)
        model.save_pretrained(str(checkpoint_dir))
        print(f"checkpoint: {checkpoint_dir}")

    if arguments.prune_vocab:
        tokens = prune_vocabulary(model.model_body, [row["text"] for row in rows])
    else:
        tokens = vocabulary_tokens(tokenizer)

    fused = build_fused_module(model, labels)
    mlmodel = export_coreml(fused, labels, arguments.max_length, arguments.quantize)

    out = arguments.out
    out.mkdir(parents=True, exist_ok=True)
    package_path = out / f"{arguments.model_name}.mlpackage"
    if package_path.exists():
        shutil.rmtree(package_path)
    mlmodel.save(str(package_path))

    vocab_path = out / f"{arguments.model_name}.vocab.txt"
    vocab_path.write_text("\n".join(tokens) + "\n", encoding="utf-8")

    do_lower_case = bool(getattr(tokenizer, "do_lower_case", False))
    manifest = {
        "version": arguments.version,
        "trainedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
        "algorithm": "setfit-sentence-transformer",
        "backbone": arguments.backbone,
        "languages": arguments.languages,
        "labels": labels,
        "maxSequenceLength": arguments.max_length,
        "doLowerCase": do_lower_case,
        "vocabularyArtifact": vocab_path.name,
        "modelArtifact": package_path.name,
        "sha256": directory_sha256(package_path),
        "taxonomyHash": file_sha256(repo_root / "packages/taxonomy/taxonomy.json"),
        "validationAccuracy": accuracy,
        "trainingCount": len(training_rows),
        "validationCount": len(validation_rows),
    }
    manifest_path = out / f"{arguments.model_name}.manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    label_counts = Counter(row["label"] for row in training_rows)
    report_path = write_training_report(
        out,
        arguments,
        accuracy,
        per_label,
        prediction_pairs,
        loss_recorder.points if loss_recorder is not None else [],
        label_counts,
    )

    print(f"model: {package_path}")
    print(f"vocab: {vocab_path} ({len(tokens)} tokens)")
    print(f"manifest: {manifest_path}")
    print(f"report: {report_path}")

    if arguments.install_ios:
        generated = repo_root / "apps/ios/GeneratedModels"
        generated.mkdir(parents=True, exist_ok=True)
        installed_package = generated / package_path.name
        if installed_package.exists():
            shutil.rmtree(installed_package)
        shutil.copytree(package_path, installed_package)
        shutil.copy2(vocab_path, generated / vocab_path.name)
        shutil.copy2(manifest_path, generated / manifest_path.name)
        print(f"installed: {generated}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
