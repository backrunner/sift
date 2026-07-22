#!/usr/bin/env python3
"""Train the on-device Core ML PII detector for Sift's sanitizer.

Token-classification model (plain per-token tags, no BIO) over a WordPiece
backbone. Training data is **synthesized**: carrier sentences from the SMS
corpus get fake PII values (phone / email / ID card / bank card / address /
name / …) injected at word boundaries, with exact character spans recorded
and projected onto tokens via the fast tokenizer's offset mapping.

Artifacts (consumed by `PIIDetectorLoader` in apps/ios):

  SiftPIIDetector.mlpackage      logits [1, seq, tags] over input_ids/attention_mask
  SiftPIIDetector.vocab.txt      WordPiece vocabulary (pruned by default)
  SiftPIIDetector.manifest.json  tags, max length, casing, version

The model is a recall-widening layer only — the Swift sanitizer always unions
it with its deterministic regex rules, so an immature model can never make
sanitization worse than rules-only.

Usage:
    uv run train_pii.py --input ../../build/pipeline/train.ndjson --install-ios
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import shutil
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

TAGS = ["O", "PHONE", "URL", "EMAIL", "ADDRESS", "CARD", "ID", "ORDER_ID", "AMOUNT", "CODE", "NAME"]
DEFAULT_BACKBONE = "distilbert-base-multilingual-cased"
DEFAULT_CLEAN_TEST = Path(__file__).resolve().parent / "Evaluation/clean-negatives.ndjson"


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=Path, required=True, help="carrier text/label NDJSON (labels unused)")
    parser.add_argument("--out", type=Path, default=None, help="output directory (default build/pii-model)")
    parser.add_argument("--backbone", default=DEFAULT_BACKBONE, help="WordPiece token-classification backbone")
    parser.add_argument("--model-name", default="SiftPIIDetector")
    parser.add_argument("--version", default="pii-0.1")
    parser.add_argument("--max-length", type=int, default=96)
    parser.add_argument("--samples", type=int, default=20000, help="synthetic training sentences to generate")
    parser.add_argument("--clean-fraction", type=float, default=0.5, help="fraction of clean negative sentences")
    parser.add_argument("--epochs", type=int, default=2)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--learning-rate", type=float, default=5e-5)
    parser.add_argument("--truncate-layers", type=int, default=2, help="keep first N encoder layers (0 = all)")
    parser.add_argument("--prune-vocab", action="store_true", default=True)
    parser.add_argument("--no-prune-vocab", dest="prune_vocab", action="store_false")
    parser.add_argument("--quantize", choices=["fp16", "int8"], default="int8")
    parser.add_argument("--device", choices=["auto", "cpu", "cuda", "mps"], default="auto")
    parser.add_argument("--install-ios", action="store_true")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--minimum-pii-f1", type=float, default=0.90)
    parser.add_argument("--maximum-clean-fpr", type=float, default=0.02)
    parser.add_argument("--clean-test-input", type=Path, default=DEFAULT_CLEAN_TEST)
    parser.add_argument("--inference-threshold", type=float, default=0.85)
    return parser.parse_args()


def locate_repo_root() -> Path:
    directory = Path(__file__).resolve().parent
    while directory != directory.parent:
        if (directory / "packages/taxonomy/taxonomy.json").exists():
            return directory
        directory = directory.parent
    raise SystemExit("error: could not locate repo root")


def select_device(requested: str) -> str:
    import torch

    cuda = torch.cuda.is_available()
    mps = bool(getattr(torch.backends, "mps", None)) and torch.backends.mps.is_available()
    if requested == "cuda" and not cuda:
        raise SystemExit("error: --device cuda unavailable (for AMD install a ROCm torch build)")
    if requested == "mps" and not mps:
        raise SystemExit("error: --device mps unavailable (needs Apple Silicon + macOS 12.3+)")
    if requested != "auto":
        return requested
    return "cuda" if cuda else ("mps" if mps else "cpu")


# --- Synthetic PII corpus ------------------------------------------------------

class FakePII:
    """Deterministic fake-value factory per (seed, language bucket)."""

    def __init__(self, rng: random.Random) -> None:
        self.rng = rng

    def value(self, tag: str, cjk: bool, japanese: bool = False) -> str:
        r = self.rng
        if tag == "PHONE":
            if cjk:
                return f"1{r.randint(3, 9)}{r.randint(1, 9)}{r.randint(10000000, 99999999)}"
            return f"+{r.randint(1, 88)} {r.randint(200, 999)} {r.randint(100, 999)} {r.randint(1000, 9999)}"
        if tag == "URL":
            host = r.choice(["t.cn", "bit.ly", "dwz.cn", "go.example.com", "m.shop.io"])
            return f"https://{host}/{r.randint(10000, 999999)}"
        if tag == "EMAIL":
            user = r.choice(["li", "wang", "john", "sara", "user", "mail"]) + str(r.randint(10, 9999))
            return f"{user}@{r.choice(['example.com', 'mail.com', 'test.org'])}"
        if tag == "ADDRESS":
            if cjk:
                return f"{r.choice(['幸福路', '中山路', '人民大道', '建国街'])}{r.randint(1, 299)}号{r.randint(1, 30)}栋{r.randint(101, 2404)}室"
            return f"{r.randint(1, 999)} {r.choice(['Elm Street', 'Oak Avenue', 'Main Road'])}, Apt {r.randint(1, 99)}"
        if tag == "CARD":
            return " ".join(str(r.randint(1000, 9999)) for _ in range(4))
        if tag == "ID":
            return f"{r.randint(110000, 659000)}{r.randint(1950, 2010)}{r.randint(1, 12):02d}{r.randint(1, 28):02d}{r.randint(100, 999)}{r.choice('0123456789X')}"
        if tag == "ORDER_ID":
            return f"{r.choice(['SF', 'YT', 'JD', ''])}{r.randint(100000000, 9999999999)}"
        if tag == "AMOUNT":
            whole = r.randint(1, 9_999_999)
            number = f"{whole:,}" if whole >= 1000 and r.random() < 0.75 else str(whole)
            if r.random() < 0.8:
                number += f".{r.randint(0, 99):02d}"
            if japanese:
                return r.choice([f"¥{number}", f"￥{number}", f"{number}円", f"JPY {number}"])
            if cjk:
                return r.choice([f"¥{number}", f"￥{number}", f"{number}元"])
            return r.choice([f"${number}", f"USD {number}", f"{number} USD"])
        if tag == "CODE":
            return str(r.randint(1000, 999999))
        if tag == "NAME":
            if cjk:
                return r.choice(["王小明", "李华", "张伟", "刘芳", "陈静", "田中太郎", "佐藤花子"])
            return r.choice(["John Smith", "Maria Garcia", "Alex Chen", "Sarah Lee"])
        return tag


def is_cjk(text: str) -> bool:
    return any("一" <= ch <= "鿿" or "぀" <= ch <= "ヿ" for ch in text)


def is_japanese(text: str) -> bool:
    return any("぀" <= ch <= "ヿ" for ch in text)


def contextualize_value(tag: str, value: str, carrier: str, rng: random.Random) -> tuple[str, int, int]:
    """Render ambiguous values with the context needed to identify their PII kind."""
    if tag != "CODE":
        return value, 0, len(value)

    japanese = any("぀" <= ch <= "ヿ" for ch in carrier)
    chinese = any("一" <= ch <= "鿿" for ch in carrier) and not japanese
    if japanese:
        prefix = rng.choice(["認証コード ", "確認コード：", "ワンタイムパスワード "])
    elif chinese:
        prefix = rng.choice(["验证码 ", "动态码：", "一次性口令 "])
    else:
        prefix = rng.choice(["verification code ", "security code: ", "OTP "])
    rendered = prefix + value
    return rendered, len(prefix), len(rendered)


def ordinary_code_negative(rng: random.Random) -> str:
    """Generate code-shaped identifiers that must remain visible."""
    suffix = rng.randint(1000, 9999)
    year = rng.randint(2024, 2032)
    templates = [
        f"故障代码 E{suffix} 已写入诊断日志，请交由技术人员排查。",
        f"商品代码 SKU-{suffix} 已加入本周销售目录。",
        f"内部构建编号 build-{year}.{rng.randint(1, 9)} 已通过测试。",
        f"活动批次 CAM-{suffix} 对应本周游戏道具交易专场。",
        f"Error code E{suffix} was recorded in the diagnostic log for support.",
        f"Product code SKU-{suffix} is active in this week's catalog.",
        f"Build identifier release-{year}.{rng.randint(1, 9)} passed all checks.",
        f"Campaign reference CAM-{suffix} belongs to the game-item sale.",
        f"障害コード E{suffix} を診断ログに記録しました。技術担当へお伝えください。",
        f"商品コード SKU-{suffix} を今週の販売一覧に追加しました。",
        f"ビルド番号 release-{year}.{rng.randint(1, 9)} はすべての検査に合格しました。",
        f"企画番号 CAM-{suffix} はゲームアイテム取引セール用です。",
    ]
    return rng.choice(templates)


def ordinary_grouped_number_negative(rng: random.Random) -> str:
    """Generate comma-grouped quantities that are not monetary amounts."""
    value = f"{rng.randint(1_000, 9_999_999):,}"
    templates = [
        f"本次活动共有{value}名参与者，请按现场安排入场。",
        f"当前积分余额为{value}分，再完成任务即可升级。",
        f"该商品累计售出{value}件，库存仍然充足。",
        f"今天已经完成{value}步，运动目标即将达成。",
        f"The event has {value} participants and registration is now closed.",
        f"Your rewards balance is now {value} points after the purchase.",
        f"The video reached {value} views during its first week.",
        f"You completed {value} steps toward today's activity goal.",
        f"イベントの参加者は{value}人で、受付は終了しました。",
        f"現在のポイント残高は{value}ポイントです。",
        f"この商品は累計{value}件販売されました。",
        f"今日は目標まであと少しの{value}歩を記録しました。",
    ]
    return rng.choice(templates)


def load_carriers(path: Path, limit: int, rng: random.Random) -> list[str]:
    carriers: list[str] = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            text = str(json.loads(line).get("text", "")).strip()
            if 8 <= len(text) <= 300:
                carriers.append(text)
    if not carriers:
        raise SystemExit(f"error: no usable carrier sentences in {path}")
    rng.shuffle(carriers)
    if len(carriers) < limit:
        carriers = carriers * (limit // len(carriers) + 1)
    return carriers[:limit]


def load_clean_test(path: Path) -> list[dict]:
    examples: list[dict] = []
    with path.open(encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            text = str(json.loads(line).get("text", "")).strip()
            if not text:
                raise SystemExit(f"error: missing text at {path}:{number}")
            examples.append({"text": text, "spans": []})
    if not examples:
        raise SystemExit(f"error: clean regression set is empty: {path}")
    return examples


def synthesize(carriers: list[str], rng: random.Random, clean_fraction: float = 0.5) -> list[dict]:
    """Injects fake PII into carrier sentences and records char spans."""
    factory = FakePII(rng)
    examples: list[dict] = []

    for carrier in carriers:
        if rng.random() < clean_fraction:
            negative_kind = rng.random()
            if negative_kind < 0.35:
                text = ordinary_code_negative(rng)
            elif negative_kind < 0.65:
                text = ordinary_grouped_number_negative(rng)
            else:
                text = carrier
            examples.append({"text": text, "spans": []})
            continue

        cjk = is_cjk(carrier)
        japanese = is_japanese(carrier)
        words = carrier.split(" ") if " " in carrier else [carrier]
        text_parts: list[str] = []
        spans: list[tuple[int, int, str]] = []
        cursor = 0

        insert_positions = sorted(rng.sample(range(len(words) + 1), k=min(rng.randint(1, 3), len(words) + 1)))
        position_index = 0
        for word_index in range(len(words) + 1):
            if position_index < len(insert_positions) and insert_positions[position_index] == word_index:
                tag = rng.choice(TAGS[1:])
                value = factory.value(tag, cjk, japanese)
                rendered, value_start, value_end = contextualize_value(tag, value, carrier, rng)
                prefix = "" if not text_parts else " "
                rendered_start = cursor + len(prefix)
                text_parts.append(prefix + rendered)
                cursor = rendered_start + len(rendered)
                spans.append((rendered_start + value_start, rendered_start + value_end, tag))
                position_index += 1
            if word_index < len(words):
                prefix = "" if not text_parts else " "
                text_parts.append(prefix + words[word_index])
                cursor += len(prefix) + len(words[word_index])

        examples.append({"text": "".join(text_parts), "spans": [list(span) for span in spans]})

    return examples


def encode_examples(examples: list[dict], tokenizer, max_length: int):
    import torch

    tag_to_id = {tag: index for index, tag in enumerate(TAGS)}
    all_ids, all_masks, all_labels = [], [], []

    for example in examples:
        encoded = tokenizer(
            example["text"],
            truncation=True,
            max_length=max_length,
            padding="max_length",
            return_offsets_mapping=True,
        )
        labels = []
        for (start, end), attention in zip(encoded["offset_mapping"], encoded["attention_mask"]):
            if attention == 0 or end == 0:
                labels.append(-100)
                continue
            tag = "O"
            for span_start, span_end, span_tag in example["spans"]:
                if start < span_end and end > span_start:
                    tag = span_tag
                    break
            labels.append(tag_to_id[tag])
        all_ids.append(encoded["input_ids"])
        all_masks.append(encoded["attention_mask"])
        all_labels.append(labels)

    return (
        torch.tensor(all_ids, dtype=torch.long),
        torch.tensor(all_masks, dtype=torch.long),
        torch.tensor(all_labels, dtype=torch.long),
    )


def threshold_predictions(logits, threshold: float):
    """Apply the runtime-style non-O confidence gate to token logits."""
    import torch

    probabilities = logits.softmax(dim=-1)
    best_probabilities, predictions = probabilities.max(dim=-1)
    outside_probabilities = probabilities[..., 0]
    keep = (predictions != 0) & (best_probabilities >= threshold) & (best_probabilities > outside_probabilities)
    return torch.where(keep, predictions, torch.zeros_like(predictions))


# --- Model surgery -------------------------------------------------------------

def truncate_layers(auto_model, keep: int) -> None:
    import torch

    for path in ("transformer.layer", "encoder.layer"):
        node = auto_model
        parts = path.split(".")
        ok = True
        for part in parts:
            if not hasattr(node, part):
                ok = False
                break
            node = getattr(node, part)
        if ok:
            parent = auto_model
            for part in parts[:-1]:
                parent = getattr(parent, part)
            setattr(parent, parts[-1], torch.nn.ModuleList(list(node)[:keep]))
            auto_model.config.num_hidden_layers = keep
            if hasattr(auto_model.config, "n_layers"):
                auto_model.config.n_layers = keep
            return
    raise SystemExit("error: --truncate-layers unsupported for this backbone")


def prune_vocabulary(model, tokenizer, texts: list[str]) -> list[str]:
    import torch

    vocab = tokenizer.get_vocab()
    keep_ids: set[int] = set(tokenizer.all_special_ids)
    for token, token_id in vocab.items():
        stripped = token[2:] if token.startswith("##") else token
        if len(stripped) == 1:
            keep_ids.add(token_id)
    for start in range(0, len(texts), 512):
        for ids in tokenizer(texts[start : start + 512], add_special_tokens=True)["input_ids"]:
            keep_ids.update(ids)

    ordered = sorted(keep_ids)
    id_to_token = {token_id: token for token, token_id in vocab.items()}
    tokens = [id_to_token[token_id] for token_id in ordered]

    base = model.base_model
    old = base.get_input_embeddings()
    index = torch.tensor(ordered, dtype=torch.long)
    new = torch.nn.Embedding(len(ordered), old.weight.shape[1])
    with torch.no_grad():
        new.weight.copy_(old.weight[index])
    base.set_input_embeddings(new)
    model.config.vocab_size = len(ordered)
    model.config.pad_token_id = tokens.index(tokenizer.pad_token or "[PAD]")
    print(f"vocabulary pruned: {len(vocab)} -> {len(tokens)}")
    return tokens


def directory_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    for file in sorted(path.rglob("*")):
        if file.is_file():
            digest.update(str(file.relative_to(path)).encode())
            digest.update(file.read_bytes())
    return digest.hexdigest()


def main() -> None:
    arguments = parse_arguments()
    repo_root = locate_repo_root()
    out = arguments.out.expanduser().resolve() if arguments.out else repo_root / "build/pii-model"
    rng = random.Random(arguments.seed)

    import numpy as np
    import torch
    from transformers import AutoModelForTokenClassification, AutoTokenizer

    torch.manual_seed(arguments.seed)
    device = select_device(arguments.device)
    print(f"device: {device}")

    tokenizer = AutoTokenizer.from_pretrained(arguments.backbone, use_fast=True)
    backend = getattr(tokenizer, "backend_tokenizer", None)
    if backend is None or type(backend.model).__name__ != "WordPiece":
        raise SystemExit("error: backbone tokenizer must be WordPiece (mBERT/DistilmBERT family)")

    carriers = load_carriers(arguments.input, arguments.samples, rng)
    if not 0 <= arguments.clean_fraction < 1:
        raise SystemExit("error: --clean-fraction must be >= 0 and < 1")
    examples = synthesize(carriers, rng, arguments.clean_fraction)
    holdout = max(len(examples) // 20, 50)
    train_examples, eval_examples = examples[holdout:], examples[:holdout]
    print(f"synthetic examples: {len(train_examples)} train, {len(eval_examples)} eval")

    model = AutoModelForTokenClassification.from_pretrained(
        arguments.backbone,
        num_labels=len(TAGS),
        id2label={index: tag for index, tag in enumerate(TAGS)},
        label2id={tag: index for index, tag in enumerate(TAGS)},
    )
    if arguments.truncate_layers > 0:
        truncate_layers(model.base_model, arguments.truncate_layers)
        print(f"encoder truncated to {arguments.truncate_layers} layers")
    model.to(device)

    ids, masks, labels = encode_examples(train_examples, tokenizer, arguments.max_length)
    optimizer = torch.optim.AdamW(model.parameters(), lr=arguments.learning_rate)
    model.train()
    steps_per_epoch = (len(ids) + arguments.batch_size - 1) // arguments.batch_size
    for epoch in range(arguments.epochs):
        permutation = torch.randperm(len(ids))
        running = 0.0
        for step in range(steps_per_epoch):
            batch = permutation[step * arguments.batch_size : (step + 1) * arguments.batch_size]
            optimizer.zero_grad()
            output = model(
                input_ids=ids[batch].to(device),
                attention_mask=masks[batch].to(device),
                labels=labels[batch].to(device),
            )
            output.loss.backward()
            optimizer.step()
            running += float(output.loss)
            if (step + 1) % 50 == 0:
                print(f"epoch {epoch + 1} step {step + 1}/{steps_per_epoch} loss {running / (step + 1):.4f}")
        print(f"epoch {epoch + 1} mean loss {running / steps_per_epoch:.4f}")

    # Token-level evaluation per tag.
    model.eval()
    eval_ids, eval_masks, eval_labels = encode_examples(eval_examples, tokenizer, arguments.max_length)
    correct: Counter = Counter()
    total: Counter = Counter()
    true_positives = 0
    false_positives = 0
    false_negatives = 0
    clean_sentence_count = 0
    clean_sentence_false_positives = 0
    with torch.no_grad():
        for start in range(0, len(eval_ids), arguments.batch_size):
            stop = start + arguments.batch_size
            logits = model(
                input_ids=eval_ids[start:stop].to(device),
                attention_mask=eval_masks[start:stop].to(device),
            ).logits
            predictions = threshold_predictions(logits, arguments.inference_threshold).cpu()
            gold = eval_labels[start:stop]
            batch_examples = eval_examples[start:stop]
            for row_predictions, row_gold, example in zip(predictions, gold, batch_examples):
                sentence_has_false_positive = False
                for predicted, expected in zip(row_predictions.tolist(), row_gold.tolist()):
                    if expected == -100:
                        continue
                    tag = TAGS[expected]
                    total[tag] += 1
                    if predicted == expected:
                        correct[tag] += 1
                    expected_is_pii = expected != 0
                    predicted_is_pii = predicted != 0
                    if expected_is_pii:
                        if predicted == expected:
                            true_positives += 1
                        else:
                            false_negatives += 1
                            false_positives += int(predicted_is_pii)
                    elif predicted_is_pii:
                        false_positives += 1
                        sentence_has_false_positive = True
                if not example["spans"]:
                    clean_sentence_count += 1
                    clean_sentence_false_positives += int(sentence_has_false_positive)
    print("token accuracy per tag:")
    for tag in TAGS:
        if total[tag]:
            print(f"  {tag}: {correct[tag] / total[tag]:.3f} ({total[tag]} tokens)")

    precision = true_positives / max(true_positives + false_positives, 1)
    recall = true_positives / max(true_positives + false_negatives, 1)
    pii_f1 = 2 * precision * recall / max(precision + recall, 1e-12)
    clean_fpr = clean_sentence_false_positives / max(clean_sentence_count, 1)
    print(f"PII micro precision: {precision:.4f}")
    print(f"PII micro recall: {recall:.4f}")
    print(f"PII micro F1: {pii_f1:.4f}")
    print(f"clean-sentence false-positive rate: {clean_fpr:.4f} ({clean_sentence_false_positives}/{clean_sentence_count})")

    clean_test_examples = load_clean_test(arguments.clean_test_input.expanduser().resolve())
    clean_ids, clean_masks, clean_labels = encode_examples(clean_test_examples, tokenizer, arguments.max_length)
    clean_test_false_positives = 0
    with torch.no_grad():
        for start in range(0, len(clean_ids), arguments.batch_size):
            stop = start + arguments.batch_size
            logits = model(
                input_ids=clean_ids[start:stop].to(device),
                attention_mask=clean_masks[start:stop].to(device),
            ).logits
            predictions = threshold_predictions(logits, arguments.inference_threshold).cpu()
            gold = clean_labels[start:stop]
            for row_predictions, row_gold, example in zip(predictions, gold, clean_test_examples[start:stop]):
                has_false_positive = any(
                    expected != -100 and predicted != 0
                    for predicted, expected in zip(row_predictions.tolist(), row_gold.tolist())
                )
                clean_test_false_positives += int(has_false_positive)
                if has_false_positive:
                    print(f"  clean regression false positive: {example['text']}")
    clean_test_fpr = clean_test_false_positives / len(clean_test_examples)
    print(
        "clean regression false-positive rate: "
        f"{clean_test_fpr:.4f} ({clean_test_false_positives}/{len(clean_test_examples)})"
    )

    effective_clean_fpr = max(clean_fpr, clean_test_fpr)
    out.mkdir(parents=True, exist_ok=True)
    quality_report_path = out / "quality-report.json"
    quality_report_path.write_text(json.dumps({
        "piiMicroPrecision": precision,
        "piiMicroRecall": recall,
        "piiMicroF1": pii_f1,
        "cleanSentenceFalsePositiveRate": clean_fpr,
        "cleanRegressionFalsePositiveRate": clean_test_fpr,
        "inferenceThreshold": arguments.inference_threshold,
        "passed": (
            pii_f1 >= arguments.minimum_pii_f1
            and effective_clean_fpr <= arguments.maximum_clean_fpr
        ),
    }, indent=2) + "\n", encoding="utf-8")
    print(f"quality report: {quality_report_path}")
    if arguments.install_ios and (
        pii_f1 < arguments.minimum_pii_f1
        or effective_clean_fpr > arguments.maximum_clean_fpr
    ):
        raise SystemExit(
            "error: refusing --install-ios because PII quality gate failed: "
            f"F1 {pii_f1:.4f} (minimum {arguments.minimum_pii_f1:.4f}), "
            f"clean FPR {effective_clean_fpr:.4f} (maximum {arguments.maximum_clean_fpr:.4f})"
        )

    # Export (CPU-only from here).
    model.to("cpu").eval()
    if arguments.prune_vocab:
        tokens = prune_vocabulary(model, tokenizer, [example["text"] for example in examples])
    else:
        vocab = tokenizer.get_vocab()
        tokens = [token for token, _ in sorted(vocab.items(), key=lambda item: item[1])]

    class LogitsWrapper(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, input_ids, attention_mask):
            return self.inner(input_ids=input_ids.to(torch.long), attention_mask=attention_mask.to(torch.long)).logits

    import coremltools as ct

    example_input = torch.ones((1, arguments.max_length), dtype=torch.int32)
    traced = torch.jit.trace(LogitsWrapper(model).eval(), (example_input, example_input))
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, arguments.max_length), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, arguments.max_length), dtype=np.int32),
        ],
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
    )
    if arguments.quantize == "int8":
        from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

        mlmodel = linear_quantize_weights(
            mlmodel,
            config=OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")),
        )

    out.mkdir(parents=True, exist_ok=True)
    package_path = out / f"{arguments.model_name}.mlpackage"
    if package_path.exists():
        shutil.rmtree(package_path)
    mlmodel.save(str(package_path))

    vocab_path = out / f"{arguments.model_name}.vocab.txt"
    vocab_path.write_text("\n".join(tokens) + "\n", encoding="utf-8")

    manifest = {
        "version": arguments.version,
        "trainedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
        "algorithm": "token-classification-pii",
        "backbone": arguments.backbone,
        "languages": ["zh", "en", "ja", "multi"],
        "labels": TAGS,
        "maxSequenceLength": arguments.max_length,
        "doLowerCase": bool(getattr(tokenizer, "do_lower_case", False)),
        "vocabularyArtifact": vocab_path.name,
        "modelArtifact": package_path.name,
        "sha256": directory_sha256(package_path),
        "taxonomyHash": None,
        "evaluation": {
            "count": len(eval_examples),
            "piiMicroPrecision": precision,
            "piiMicroRecall": recall,
            "piiMicroF1": pii_f1,
            "cleanSentenceFalsePositiveRate": clean_fpr,
            "cleanSentenceCount": clean_sentence_count,
            "cleanRegressionFalsePositiveRate": clean_test_fpr,
            "cleanRegressionCount": len(clean_test_examples),
            "inferenceThreshold": arguments.inference_threshold,
        },
    }
    manifest_path = out / f"{arguments.model_name}.manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(f"model: {package_path}")
    print(f"vocab: {vocab_path} ({len(tokens)} tokens)")
    print(f"manifest: {manifest_path}")

    if arguments.install_ios:
        generated = repo_root / "apps/ios/GeneratedModels"
        generated.mkdir(parents=True, exist_ok=True)
        installed = generated / package_path.name
        if installed.exists():
            shutil.rmtree(installed)
        shutil.copytree(package_path, installed)
        shutil.copy2(vocab_path, generated / vocab_path.name)
        shutil.copy2(manifest_path, generated / manifest_path.name)
        print(f"installed: {generated}")


if __name__ == "__main__":
    main()
