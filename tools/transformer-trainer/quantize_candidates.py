#!/usr/bin/env python3
"""Build and evaluate every configured Core ML quantization candidate."""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
import math
import shutil
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from model_contract import ABSTAIN_LABEL, MODEL_ABI_V1, model_labels


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fp16-model", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True, help="Hugging Face checkpoint containing the tokenizer")
    parser.add_argument("--tokenizer-artifact", type=Path, required=True)
    parser.add_argument("--calibration-input", type=Path, required=True)
    parser.add_argument("--fixed-holdout", type=Path, required=True)
    parser.add_argument("--promotion-holdout", type=Path, required=True)
    parser.add_argument("--conversation-holdout", type=Path, required=True)
    parser.add_argument("--taxonomy", type=Path, required=True)
    parser.add_argument("--profiles", type=Path, default=Path(__file__).with_name("quantization-profiles.json"))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--model-name", default="SiftSignalModel")
    parser.add_argument("--version", required=True)
    parser.add_argument("--model-abi", default=MODEL_ABI_V1)
    parser.add_argument("--release-sequence", type=int, required=True)
    parser.add_argument("--minimum-app-build", type=int, required=True)
    parser.add_argument("--maximum-app-build", type=int, required=True)
    parser.add_argument("--calibration-limit", type=int, default=256)
    parser.add_argument("--max-length", type=int, default=96)
    parser.add_argument(
        "--profile-id",
        action="append",
        default=[],
        help="generate only the named profile(s); fp16-baseline is included automatically",
    )
    parser.add_argument(
        "--reuse-existing-candidates",
        action="store_true",
        help="reuse a saved candidate only when its complete build identity matches",
    )
    parser.add_argument(
        "--qat-model",
        action="append",
        default=[],
        metavar="PROFILE_ID=MLPACKAGE",
        help="FP16 export from an externally QAT-trained checkpoint for a QAT fallback profile",
    )
    return parser.parse_args()


def read_ndjson(path: Path, limit: int | None = None) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                record = json.loads(line)
                rows.append({"text": str(record["text"]), "label": str(record["label"])})
                if limit is not None and len(rows) >= limit:
                    break
    if not rows:
        raise SystemExit(f"error: empty dataset: {path}")
    return rows


def directory_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    for file in sorted(item for item in path.rglob("*") if item.is_file()):
        digest.update(file.relative_to(path).as_posix().encode("utf-8"))
        with file.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    return digest.hexdigest()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def tokenizer_artifact_name(model_name: str) -> str:
    return f"{model_name}.tokenizer.siftbpe"


def run_message_filter_artifact_suite(
    candidate_dir: Path,
    model_path: Path,
    tokenizer_path: Path,
    manifest_path: Path,
    fixed_holdout: Path,
    promotion_holdout: Path,
    conversation_holdout: Path,
) -> dict[str, Any]:
    swift = shutil.which("swift")
    if swift is None:
        raise SystemExit("error: Swift is required for the MessageFilter artifact suite")
    output = candidate_dir / "message-filter-actions.json"
    ios_package = Path(__file__).resolve().parents[2] / "apps/ios"
    result = subprocess.run(
        [
            swift, "run", "--package-path", str(ios_package), "MessageFilterArtifactTests",
            "--model", str(model_path),
            "--tokenizer", str(tokenizer_path),
            "--manifest", str(manifest_path),
            "--fixed", str(fixed_holdout),
            "--promotion", str(promotion_holdout),
            "--conversation", str(conversation_holdout),
            "--output", str(output),
            "--readable-cases",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        if output.is_file():
            report = json.loads(output.read_text(encoding="utf-8"))
            report["suiteFailure"] = result.stderr.strip() or f"exit {result.returncode}"
            return report
        raise SystemExit(f"error: MessageFilter artifact suite failed:\n{result.stderr.strip()}")
    return json.loads(output.read_text(encoding="utf-8"))


MODEL_SMOKE_WORKER = """
import math
import sys
import coremltools as ct
import numpy as np

model_path, max_length, compute_unit = sys.argv[1], int(sys.argv[2]), sys.argv[3]
model = ct.models.MLModel(model_path, compute_units=getattr(ct.ComputeUnit, compute_unit))
sample = {
    "input_ids": np.ones((1, max_length), dtype=np.int32),
    "attention_mask": np.ones((1, max_length), dtype=np.int32),
}
output = model.predict(sample)
probability_maps = [value for value in output.values() if isinstance(value, dict)]
if not probability_maps:
    print("missing_probability_output")
    raise SystemExit(2)
probabilities = [float(value) for value in probability_maps[0].values()]
if not probabilities or not all(math.isfinite(value) for value in probabilities):
    print("non_finite_probabilities")
    raise SystemExit(3)
if not 0.99 <= sum(probabilities) <= 1.01:
    print("invalid_probability_sum")
    raise SystemExit(4)
"""


def model_smoke_failure(model_path: Path, max_length: int) -> str | None:
    for compute_unit in ("CPU_ONLY", "ALL"):
        try:
            result = subprocess.run(
                [sys.executable, "-c", MODEL_SMOKE_WORKER, str(model_path), str(max_length), compute_unit],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                text=True,
                timeout=180,
            )
        except subprocess.TimeoutExpired:
            return f"{compute_unit.lower()}_smoke_timeout"
        if result.returncode != 0:
            detail = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else "native_failure"
            return f"{compute_unit.lower()}_smoke_{detail}_exit_{result.returncode}"
    return None


def directory_bytes(path: Path) -> int:
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def encode_samples(tokenizer, rows: list[dict[str, str]], max_length: int) -> list[dict[str, Any]]:
    import numpy as np

    samples: list[dict[str, Any]] = []
    for row in rows:
        encoded = tokenizer(
            row["text"],
            truncation=True,
            padding="max_length",
            max_length=max_length,
            return_tensors="np",
        )
        samples.append({
            "input_ids": encoded["input_ids"].astype(np.int32),
            "attention_mask": encoded["attention_mask"].astype(np.int32),
        })
    return samples


def quantize_weights(model, profile: dict[str, Any]):
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )

    if profile["weightBits"] < 16:
        weight_options: dict[str, Any] = {
            "mode": "linear_symmetric",
            "dtype": f"int{profile['weightBits']}",
            "granularity": profile["granularity"].replace("-", "_"),
        }
        if profile.get("blockSize") is not None:
            weight_options["block_size"] = profile["blockSize"]
        model = linear_quantize_weights(
            model,
            config=OptimizationConfig(global_config=OpLinearQuantizerConfig(**weight_options)),
        )
    return model


def enable_coremltools9_calibration_cache() -> bool:
    """Reuse Core ML Tools 9.0's otherwise-unused ModelDebugger model cache."""
    import coremltools as ct

    if ct.__version__ != "9.0":
        return False
    from coremltools import _SPECIFICATION_VERSION_IOS_16
    from coremltools.optimize.coreml.experimental._model_debugger import ModelDebugger, ModelInfo

    if getattr(ModelDebugger, "_sift_reuses_calibration_model", False):
        return True

    def cached_predict_intermediate_outputs(
        self,
        inputs,
        intermediate_output_names,
        compute_units=ct.ComputeUnit.CPU_ONLY,
    ):
        model_key = frozenset(intermediate_output_names)
        cached_models = getattr(self, "_ModelDebugger__cached_models")
        model = cached_models.get(model_key)
        if model is None:
            cloned_spec = self.__class__.clone_spec(self.model_info.spec)
            if cloned_spec.specificationVersion < _SPECIFICATION_VERSION_IOS_16:
                cloned_spec.specificationVersion = _SPECIFICATION_VERSION_IOS_16
            cloned_model_info = ModelInfo(
                self.__class__.get_program_info(cloned_spec.mlProgram), cloned_spec
            )
            cloned_block_info = self.__class__.get_any_block(cloned_model_info)
            for output_name in intermediate_output_names:
                output_type = self.__class__.get_output_feature_type(
                    output_name, self.block_info.operations
                )
                if output_type is None:
                    continue
                cloned_block_info.spec.outputs.append(output_name)
                cloned_output = ct.proto.Model_pb2.FeatureDescription()
                cloned_output.name = output_name
                cloned_output.type.multiArrayType.dataType = output_type
                cloned_model_info.spec.description.output.append(cloned_output)
            model = ct.models.MLModel(
                cloned_spec,
                weights_dir=self.weights_dir,
                compute_units=compute_units,
                skip_model_load=False,
            )
            cached_models[model_key] = model
        return model.predict(inputs)

    ModelDebugger.predict_intermediate_outputs = cached_predict_intermediate_outputs
    ModelDebugger._sift_reuses_calibration_model = True
    return True


def quantize_activations(model, calibration_samples: list[dict[str, Any]]):
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_activations,
    )
    from coremltools.converters.mil.mil import types

    def selects_float_activations(op) -> bool:
        x = op.inputs.get("x")
        if x is None or not types.is_float(x.dtype):
            return False
        if op.op_type == "add":
            y = op.inputs.get("y")
            return y is not None and types.is_float(y.dtype)
        return True

    activation_config = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(
            mode="linear_symmetric",
            dtype="int8",
            granularity="per_tensor",
        ),
        op_selector=selects_float_activations,
        is_deprecated=True,
    )
    enable_coremltools9_calibration_cache()
    return linear_quantize_activations(
        model,
        config=activation_config,
        sample_data=calibration_samples,
    )


def predicted_label_and_probabilities(output: dict[str, Any], labels: list[str]) -> tuple[str, list[float]]:
    for value in output.values():
        if isinstance(value, dict) and value:
            probabilities = [float(value.get(label, 0.0)) for label in labels]
            best = max(range(len(probabilities)), key=probabilities.__getitem__)
            return labels[best], probabilities
    for value in output.values():
        if isinstance(value, str):
            return value, [1.0 if label == value else 0.0 for label in labels]
        if hasattr(value, "reshape") and int(value.size) == len(labels):
            probabilities = [float(item) for item in value.reshape(-1)]
            best = max(range(len(probabilities)), key=probabilities.__getitem__)
            return labels[best], probabilities
    raise RuntimeError("Core ML output contains neither probabilities nor a predicted label")


def language(text: str) -> str:
    if any("\u3040" <= character <= "\u30ff" for character in text):
        return "ja"
    if any("\u4e00" <= character <= "\u9fff" for character in text):
        return "zh"
    return "en"


def select_calibration_rows(rows: list[dict[str, str]], limit: int) -> list[dict[str, str]]:
    if limit <= 0:
        raise SystemExit("error: calibration limit must be positive")
    buckets: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        buckets[(row["label"], language(row["text"]))].append(row)
    selected: list[dict[str, str]] = []
    indexes = {key: 0 for key in buckets}
    keys = sorted(buckets)
    while len(selected) < min(limit, len(rows)):
        added = False
        for key in keys:
            index = indexes[key]
            if index >= len(buckets[key]):
                continue
            selected.append(buckets[key][index])
            indexes[key] = index + 1
            added = True
            if len(selected) >= limit:
                break
        if not added:
            break
    return selected


def rows_sha256(rows: list[dict[str, str]]) -> str:
    digest = hashlib.sha256()
    for row in rows:
        digest.update(
            (json.dumps(row, sort_keys=True, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        )
    return digest.hexdigest()


def candidate_build_identity(
    profile: dict[str, Any],
    source_model_sha256: str,
    tokenizer_sha256: str,
    calibration: dict[str, Any],
    max_length: int,
    coremltools_version: str,
) -> dict[str, Any]:
    if profile["method"] == "baseline":
        quantization_order = "baseline"
    elif profile["activationBits"] == 8:
        quantization_order = "activation-then-weight"
    else:
        quantization_order = "weight-only"
    return {
        "schemaVersion": 2,
        "profile": profile,
        "quantizationOrder": quantization_order,
        "sourceModelSHA256": source_model_sha256,
        "tokenizerSHA256": tokenizer_sha256,
        "calibration": calibration,
        "maxSequenceLength": max_length,
        "coremltoolsVersion": coremltools_version,
    }


def reusable_model(model_path: Path, identity_path: Path, expected_identity: dict[str, Any]) -> bool:
    if not model_path.is_dir() or not identity_path.is_file():
        return False
    try:
        actual_identity = json.loads(identity_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return actual_identity == expected_identity


def reusable_candidate(
    candidate_dir: Path,
    model_path: Path,
    tokenizer_path: Path,
    expected_identity: dict[str, Any],
) -> bool:
    identity_path = candidate_dir / "candidate-build-identity.json"
    if not tokenizer_path.is_file():
        return False
    return reusable_model(model_path, identity_path, expected_identity)


def taxonomy_actions(path: Path) -> dict[str, str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    actions: dict[str, str] = {}
    for group in payload["groups"]:
        for leaf in group["leaves"]:
            actions[leaf["id"]] = leaf.get("systemAction", group["systemAction"])
    return actions


def checkpoint_labels(path: Path) -> list[str]:
    config_path = path / "config.json"
    if not config_path.is_file():
        raise SystemExit(f"error: checkpoint config missing: {config_path}")
    payload = json.loads(config_path.read_text(encoding="utf-8"))
    id_to_label = payload.get("id2label")
    if not isinstance(id_to_label, dict) or not id_to_label:
        raise SystemExit("error: checkpoint config has no id2label mapping")
    try:
        ordered = [str(label) for _, label in sorted(id_to_label.items(), key=lambda item: int(item[0]))]
    except (TypeError, ValueError) as error:
        raise SystemExit("error: checkpoint id2label keys must be integers") from error
    if len(ordered) != len(set(ordered)):
        raise SystemExit("error: checkpoint labels must be unique")
    return ordered


def evaluate(model, samples, rows, labels, actions) -> dict[str, Any]:
    predictions: list[str] = []
    finite = True
    sums_valid = True
    language_totals: dict[str, int] = defaultdict(int)
    language_correct: dict[str, int] = defaultdict(int)
    action_correct = 0
    benign_to_junk = 0
    promotion_false_positives = 0
    promotion_negatives = 0
    scam_total = 0
    scam_correct = 0

    for sample, row in zip(samples, rows):
        predicted, probabilities = predicted_label_and_probabilities(model.predict(sample), labels)
        predictions.append(predicted)
        finite = finite and all(math.isfinite(value) for value in probabilities)
        sums_valid = sums_valid and 0.99 <= sum(probabilities) <= 1.01
        row_language = language(row["text"])
        language_totals[row_language] += 1
        if predicted == row["label"]:
            language_correct[row_language] += 1
        expected_action = actions[row["label"]]
        predicted_action = actions[predicted]
        action_correct += int(expected_action == predicted_action)
        benign_to_junk += int(expected_action != "junk" and predicted_action == "junk")
        if expected_action != "promotion":
            promotion_negatives += 1
            promotion_false_positives += int(predicted_action == "promotion")
        if expected_action == "junk":
            scam_total += 1
            scam_correct += int(predicted_action == "junk")

    return {
        "predictions": predictions,
        "accuracy": sum(predicted == row["label"] for predicted, row in zip(predictions, rows)) / len(rows),
        "languageAccuracy": {
            key: language_correct[key] / total for key, total in sorted(language_totals.items())
        },
        "languageCorrect": dict(language_correct),
        "languageTotals": dict(language_totals),
        "probabilitiesFinite": finite,
        "probabilitySumsValid": sums_valid,
        "actionAccuracy": action_correct / len(rows),
        "benignOrTransactionToJunk": benign_to_junk,
        "promotionFalsePositiveRate": promotion_false_positives / max(promotion_negatives, 1),
        "scamJunkRecall": scam_correct / max(scam_total, 1),
    }


def combined_language_accuracy(*evaluations: dict[str, Any]) -> dict[str, float]:
    correct: dict[str, int] = defaultdict(int)
    totals: dict[str, int] = defaultdict(int)
    for evaluation in evaluations:
        for language_id, count in evaluation["languageCorrect"].items():
            correct[language_id] += count
        for language_id, count in evaluation["languageTotals"].items():
            totals[language_id] += count
    return {
        language_id: correct[language_id] / count
        for language_id, count in sorted(totals.items())
    }


def remote_artifacts(model_path: Path, tokenizer_path: Path, root: Path) -> list[dict[str, Any]]:
    files = sorted(item for item in model_path.rglob("*") if item.is_file()) + [tokenizer_path]
    return [
        {
            "path": item.relative_to(root).as_posix(),
            "sha256": file_sha256(item),
            "byteCount": item.stat().st_size,
        }
        for item in files
    ]


def parse_qat_models(values: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        profile_id, separator, path = value.partition("=")
        if not separator:
            raise SystemExit("error: --qat-model must use PROFILE_ID=MLPACKAGE")
        result[profile_id] = Path(path).expanduser().resolve()
    return result


def main() -> None:
    arguments = parse_arguments()
    import coremltools as ct
    from transformers import AutoTokenizer

    profiles_payload = json.loads(arguments.profiles.read_text(encoding="utf-8"))
    if profiles_payload.get("schemaVersion") != 1 or not isinstance(profiles_payload.get("profiles"), list):
        raise SystemExit("error: unsupported quantization profile schema")
    configured_profiles = profiles_payload["profiles"]
    profiles_by_id = {profile["id"]: profile for profile in configured_profiles}
    if len(profiles_by_id) != len(configured_profiles):
        raise SystemExit("error: duplicate quantization profile id")
    requested_profile_ids = set(arguments.profile_id)
    unknown_profile_ids = requested_profile_ids - profiles_by_id.keys()
    if unknown_profile_ids:
        raise SystemExit(f"error: unknown quantization profile(s): {', '.join(sorted(unknown_profile_ids))}")
    baseline_profile = profiles_by_id.get("fp16-baseline")
    if baseline_profile is None:
        raise SystemExit("error: fp16-baseline profile is required")
    qat_models = parse_qat_models(arguments.qat_model)
    profiles = [baseline_profile]
    for profile in configured_profiles:
        if profile["id"] == "fp16-baseline":
            continue
        if requested_profile_ids and profile["id"] not in requested_profile_ids:
            continue
        if profile.get("enabledWhenPTQQualityFails") and profile["id"] not in qat_models:
            if profile["id"] in requested_profile_ids:
                raise SystemExit(f"error: {profile['id']} requires --qat-model {profile['id']}=MLPACKAGE")
            continue
        profiles.append(profile)
    tokenizer = AutoTokenizer.from_pretrained(arguments.checkpoint)
    all_calibration_rows = read_ndjson(arguments.calibration_input)
    calibration_source_sha256 = file_sha256(arguments.calibration_input)
    tokenizer_sha256 = file_sha256(arguments.tokenizer_artifact)
    published_tokenizer_name = tokenizer_artifact_name(arguments.model_name)
    fixed_rows = read_ndjson(arguments.fixed_holdout)
    promotion_rows = read_ndjson(arguments.promotion_holdout)
    conversation_rows = read_ndjson(arguments.conversation_holdout)
    fixed_samples = encode_samples(tokenizer, fixed_rows, arguments.max_length)
    promotion_samples = encode_samples(tokenizer, promotion_rows, arguments.max_length)
    conversation_samples = encode_samples(tokenizer, conversation_rows, arguments.max_length)
    actions = taxonomy_actions(arguments.taxonomy)
    labels = checkpoint_labels(arguments.checkpoint)
    expected_labels = model_labels(set(actions))
    if set(labels) != expected_labels:
        missing = sorted(expected_labels - set(labels))
        unknown = sorted(set(labels) - expected_labels)
        raise SystemExit(f"error: checkpoint label contract mismatch; missing={missing}, unknown={unknown}")
    actions[ABSTAIN_LABEL] = "none"
    arguments.out.mkdir(parents=True, exist_ok=True)
    reports_dir = arguments.out / "reports"
    reports_dir.mkdir(exist_ok=True)
    trained_at = utc_timestamp()

    baseline_predictions: dict[str, list[str]] = {}
    source_model_hashes: dict[Path, str] = {}
    for profile in profiles:
        source_path = qat_models.get(profile["id"], arguments.fp16_model).resolve()
        if not source_path.is_dir():
            raise SystemExit(f"error: source model does not exist: {source_path}")
        if source_path not in source_model_hashes:
            source_model_hashes[source_path] = directory_sha256(source_path)
        calibration_limit = int(profile.get("calibrationLimit", arguments.calibration_limit))
        selected_calibration_rows = select_calibration_rows(all_calibration_rows, calibration_limit)
        requires_calibration = profile["activationBits"] == 8
        calibration = {
            "required": requires_calibration,
            "selectionStrategy": "round-robin-label-language-v1",
            "sourceSHA256": calibration_source_sha256,
            "sampleSHA256": rows_sha256(selected_calibration_rows),
            "sampleCount": len(selected_calibration_rows),
            "limit": calibration_limit,
        } if requires_calibration else {"required": False}
        expected_build_identity = candidate_build_identity(
            profile,
            source_model_hashes[source_path],
            tokenizer_sha256,
            calibration,
            arguments.max_length,
            ct.__version__,
        )
        profile_manifest = {
            "identifier": profile["id"],
            "weightBits": profile["weightBits"],
            "activationBits": profile["activationBits"],
            "method": profile["method"],
            "granularity": profile["granularity"],
            "quantizationOrder": expected_build_identity["quantizationOrder"],
            **({"blockSize": profile["blockSize"]} if profile.get("blockSize") else {}),
            "calibration": calibration,
        }
        candidate_dir = arguments.out / "candidates" / profile["id"]
        model_path = candidate_dir / f"{arguments.model_name}.mlpackage"
        tokenizer_path = candidate_dir / published_tokenizer_name
        can_reuse = arguments.reuse_existing_candidates and reusable_candidate(
            candidate_dir, model_path, tokenizer_path, expected_build_identity
        )
        if can_reuse:
            print(f"reusing candidate: {profile['id']}")
        else:
            if candidate_dir.exists():
                shutil.rmtree(candidate_dir)
            candidate_dir.mkdir(parents=True)
            if requires_calibration:
                activation_identity = {
                    "schemaVersion": 1,
                    "stage": "activation-calibration",
                    "sourceModelSHA256": source_model_hashes[source_path],
                    "tokenizerSHA256": tokenizer_sha256,
                    "calibration": calibration,
                    "maxSequenceLength": arguments.max_length,
                    "coremltoolsVersion": ct.__version__,
                    "activationBits": 8,
                    "mode": "linear_symmetric",
                    "granularity": "per_tensor",
                }
                activation_key = (
                    f"a8-{source_model_hashes[source_path][:12]}-"
                    f"{calibration['sampleSHA256'][:12]}"
                )
                activation_dir = arguments.out / "activation-bases" / activation_key
                activation_model_path = activation_dir / "ActivationCalibrated.mlpackage"
                activation_identity_path = activation_dir / "activation-build-identity.json"
                if reusable_model(
                    activation_model_path,
                    activation_identity_path,
                    activation_identity,
                ):
                    activation_model = ct.models.MLModel(
                        str(activation_model_path), compute_units=ct.ComputeUnit.ALL
                    )
                    print(f"reusing activation calibration: {activation_key}")
                else:
                    if activation_dir.exists():
                        shutil.rmtree(activation_dir)
                    activation_dir.mkdir(parents=True)
                    source_model = ct.models.MLModel(
                        str(source_path), compute_units=ct.ComputeUnit.ALL
                    )
                    calibration_samples = encode_samples(
                        tokenizer, selected_calibration_rows, arguments.max_length
                    )
                    activation_model = quantize_activations(source_model, calibration_samples)
                    activation_model.save(str(activation_model_path))
                    activation_identity_path.write_text(
                        json.dumps(activation_identity, indent=2, ensure_ascii=False) + "\n",
                        encoding="utf-8",
                    )
                    del source_model
                candidate = quantize_weights(activation_model, profile)
                del activation_model
            else:
                source_model = ct.models.MLModel(
                    str(source_path), compute_units=ct.ComputeUnit.ALL
                )
                candidate = source_model if profile["method"] == "baseline" else quantize_weights(
                    source_model, profile
                )
                if source_model is not candidate:
                    del source_model
            candidate.save(str(model_path))
            shutil.copy2(arguments.tokenizer_artifact, tokenizer_path)
            (candidate_dir / "candidate-build-identity.json").write_text(
                json.dumps(expected_build_identity, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            del candidate
            gc.collect()

        smoke_failure = model_smoke_failure(model_path, arguments.max_length)
        if smoke_failure is not None:
            if profile["id"] == "fp16-baseline":
                raise SystemExit(f"error: FP16 baseline failed model smoke: {smoke_failure}")
            artifact_sha = directory_sha256(model_path)
            report = {
                "schemaVersion": 1,
                "profileID": profile["id"],
                "artifactSHA256": artifact_sha,
                "downloadBytes": directory_bytes(model_path) + tokenizer_path.stat().st_size,
                "quantizationProfile": profile_manifest,
                "generationError": smoke_failure,
                "metrics": {
                    "fixedAccuracy": 0,
                    "promotionAccuracy": 0,
                    "conversationAccuracy": 0,
                    "fp16Top1Agreement": 0,
                    "probabilitiesFinite": False,
                    "probabilitySumsValid": False,
                    "languageAccuracy": {"zh": 0, "en": 0, "ja": 0},
                },
                "messageFilterActions": {
                    "fixedAccuracy": 0,
                    "promotionAccuracy": 0,
                    "benignOrTransactionToJunk": 1,
                    "promotionFalsePositiveRate": 1,
                    "scamJunkRecall": 0,
                    "rulesOverrideRate": 0,
                },
                "deviceMetrics": {
                    "accelerationVerified": False,
                    "peakPhysicalFootprintBytes": 0,
                    "peakPhysicalFootprintIncreaseBytes": 0,
                    "p95LatencyMilliseconds": 0,
                },
            }
            (reports_dir / f"{profile['id']}.report.json").write_text(
                json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
            )
            print(f"candidate rejected: {profile['id']} ({smoke_failure})")
            continue

        candidate = ct.models.MLModel(str(model_path), compute_units=ct.ComputeUnit.ALL)

        fixed = evaluate(candidate, fixed_samples, fixed_rows, labels, actions)
        promotion = evaluate(candidate, promotion_samples, promotion_rows, labels, actions)
        conversation = evaluate(candidate, conversation_samples, conversation_rows, labels, actions)
        language_accuracy = combined_language_accuracy(fixed, promotion)
        if profile["id"] == "fp16-baseline":
            baseline_predictions = {
                "fixed": fixed["predictions"],
                "promotion": promotion["predictions"],
                "conversation": conversation["predictions"],
            }
        agreement_total = len(fixed_rows) + len(promotion_rows) + len(conversation_rows)
        agreement_correct = sum(
            predicted == baseline
            for predicted, baseline in zip(fixed["predictions"], baseline_predictions.get("fixed", fixed["predictions"]))
        ) + sum(
            predicted == baseline
            for predicted, baseline in zip(promotion["predictions"], baseline_predictions.get("promotion", promotion["predictions"]))
        ) + sum(
            predicted == baseline
            for predicted, baseline in zip(conversation["predictions"], baseline_predictions.get("conversation", conversation["predictions"]))
        )
        model_path = candidate_dir / f"{arguments.model_name}.mlpackage"
        tokenizer_path = candidate_dir / published_tokenizer_name
        artifact_sha = directory_sha256(model_path)
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
            "quantizationProfile": profile_manifest,
            "validationMetrics": {
                "fixedAccuracy": fixed["accuracy"],
                "promotionAccuracy": promotion["accuracy"],
                "conversationAccuracy": conversation["accuracy"],
                "fp16Agreement": agreement_correct / agreement_total,
                "languageAccuracy": language_accuracy,
            },
            "version": arguments.version,
            "trainedAt": trained_at,
            "algorithm": "supervised-sequence-classification",
            "backbone": arguments.checkpoint.name,
            "languages": ["zh", "en", "ja"],
            "labels": labels,
            "maxSequenceLength": arguments.max_length,
            "doLowerCase": bool(getattr(tokenizer, "do_lower_case", False)),
            "tokenizerKind": "bpe",
            "tokenizerArtifact": tokenizer_path.name,
            "modelArtifact": model_path.name,
            "sha256": artifact_sha,
            "taxonomyHash": file_sha256(arguments.taxonomy),
            "tokenizerSHA256": tokenizer_sha256,
        }
        artifacts = remote_artifacts(model_path, tokenizer_path, candidate_dir)
        manifest["remoteArtifacts"] = artifacts
        manifest["downloadBytes"] = sum(item["byteCount"] for item in artifacts)
        manifest_path = candidate_dir / f"{arguments.model_name}.manifest.json"
        manifest_path.write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        message_filter_actions = run_message_filter_artifact_suite(
            candidate_dir,
            model_path,
            tokenizer_path,
            manifest_path,
            arguments.fixed_holdout,
            arguments.promotion_holdout,
            arguments.conversation_holdout,
        )
        report = {
            "schemaVersion": 1,
            "profileID": profile["id"],
            "artifactSHA256": artifact_sha,
            "downloadBytes": manifest["downloadBytes"],
            "quantizationProfile": profile_manifest,
            "metrics": {
                "fixedAccuracy": fixed["accuracy"],
                "promotionAccuracy": promotion["accuracy"],
                "conversationAccuracy": conversation["accuracy"],
                "conversationActionAccuracy": conversation["actionAccuracy"],
                "fp16Top1Agreement": agreement_correct / agreement_total,
                "probabilitiesFinite": fixed["probabilitiesFinite"] and promotion["probabilitiesFinite"] and conversation["probabilitiesFinite"],
                "probabilitySumsValid": fixed["probabilitySumsValid"] and promotion["probabilitySumsValid"] and conversation["probabilitySumsValid"],
                "languageAccuracy": language_accuracy,
            },
            "messageFilterActions": message_filter_actions,
            "deviceMetrics": {
                "accelerationVerified": False,
                "peakPhysicalFootprintBytes": 0,
                "peakPhysicalFootprintIncreaseBytes": 0,
                "p95LatencyMilliseconds": 0,
            },
        }
        (reports_dir / f"{profile['id']}.report.json").write_text(
            json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        print(f"candidate: {profile['id']} ({manifest['downloadBytes']:,} bytes)")
        del candidate
        gc.collect()


if __name__ == "__main__":
    main()
