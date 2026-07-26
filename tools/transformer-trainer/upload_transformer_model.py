#!/usr/bin/env python3
"""Validate and upload a Sift transformer Core ML release.

The app checks a signed channel manifest, then downloads an immutable signed
release and the files listed in `remoteArtifacts`. `.mlpackage` is a directory
package, so the release lists each file instead of uploading a zip.

Examples:

  # Dry-run a freshly trained model.
  python3 tools/transformer-trainer/upload_transformer_model.py \
    --model-dir build/pipeline/transformer-model/quantization-tournament/candidates/w8a16-channel-ptq \
    --selection build/pipeline/transformer-model/selected-candidate.json \
    --signing-key ~/.config/sift/model-release-ed25519.pem \
    --signing-key-id release-2026 \
    --base-url https://sift.alkinum.io/models \
    --dry-run

  # Copy into a local static/CDN publish directory.
  python3 tools/transformer-trainer/upload_transformer_model.py \
    --model-dir build/pipeline/transformer-model/quantization-tournament/candidates/w8a16-channel-ptq \
    --selection build/pipeline/transformer-model/selected-candidate.json \
    --signing-key ~/.config/sift/model-release-ed25519.pem \
    --signing-key-id release-2026 \
    --base-url https://sift.alkinum.io/models \
    --dest-dir /tmp/sift-models

  # Upload to Cloudflare R2 with the AWS CLI. Copy
  # .env.signal-model.example to .env.signal-model first; do not
  # commit the real dotenv file.
  python3 tools/transformer-trainer/upload_transformer_model.py \
    --model-dir build/pipeline/transformer-model/quantization-tournament/candidates/w8a16-channel-ptq \
    --selection build/pipeline/transformer-model/selected-candidate.json \
    --r2-bucket "$SIFT_MODEL_R2_BUCKET" \
    --verify-http

  # Any other object-storage CLI can still be used via a command template.
  # The template is split with shlex and supports {src}, {path},
  # {content_type}, and {cache_control}.
  python3 tools/transformer-trainer/upload_transformer_model.py \
    --model-dir build/pipeline/transformer-model/quantization-tournament/candidates/w8a16-channel-ptq \
    --selection build/pipeline/transformer-model/selected-candidate.json \
    --signing-key ~/.config/sift/model-release-ed25519.pem \
    --signing-key-id release-2026 \
    --base-url https://sift.alkinum.io/models \
    --upload-command 'rclone copyto {src} r2:sift-models/models/{path}'
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import mimetypes
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from string import Formatter
from typing import Any


DEFAULT_MODEL_NAME = "SiftSignalModel"
DEFAULT_ARTIFACT_CACHE_CONTROL = "public, max-age=31536000, immutable"
DEFAULT_MANIFEST_CACHE_CONTROL = "public, max-age=300"
DEFAULT_DOTENV_NAME = ".env.signal-model"
SIGNED_VALIDATION_METRIC_FIELDS = (
    "fixedAccuracy",
    "promotionAccuracy",
    "fp16Agreement",
    "languageAccuracy",
)
SIGNED_QUANTIZATION_PROFILE_FIELDS = (
    "identifier",
    "weightBits",
    "activationBits",
    "method",
    "granularity",
    "blockSize",
)


@dataclass(frozen=True)
class UploadItem:
    source: Path
    path: str
    content_type: str
    cache_control: str


def parse_arguments() -> argparse.Namespace:
    raw = sys.argv[1:]
    if raw and raw[0] == "--":
        raw = raw[1:]
    load_dotenv_from_arguments(raw)

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model-dir", type=Path, required=True, help="directory containing the exported transformer artifacts")
    parser.add_argument("--selection", type=Path, required=True, help="selected-candidate.json produced by the quantization gate")
    parser.add_argument("--release-id", default=None, help="immutable release directory name; defaults to manifest version")
    parser.add_argument("--channel-path", default="channels/v2/SiftSignalModel.channel.json")
    parser.add_argument(
        "--compatible-release-manifest-url",
        action="append",
        default=[],
        help="immutable signed release manifest to add to the compatibility catalog; repeat as needed",
    )
    parser.add_argument(
        "--reuse-artifacts-base-url",
        default=None,
        help=(
            "publish a metadata-only release whose artifacts remain at this HTTPS base URL; "
            "every referenced object is hash-verified before publication"
        ),
    )
    parser.add_argument(
        "--no-preserve-channel-history",
        action="store_true",
        help="do not merge the currently published signed channel (intended only for isolated tests)",
    )
    parser.add_argument("--signing-key", type=Path, default=os.getenv("SIFT_MODEL_SIGNING_KEY"))
    parser.add_argument("--signing-key-id", default=os.getenv("SIFT_MODEL_SIGNING_KEY_ID"))
    parser.add_argument("--model-name", default=DEFAULT_MODEL_NAME)
    parser.add_argument(
        "--base-url",
        default=os.getenv("SIFT_SIGNAL_MODEL_BASE_URL"),
        help="public URL prefix used by the iOS app; can also come from SIFT_SIGNAL_MODEL_BASE_URL",
    )
    parser.add_argument("--dest-dir", type=Path, default=None, help="optional local destination directory")
    parser.add_argument("--r2-bucket", default=os.getenv("SIFT_MODEL_R2_BUCKET"), help="Cloudflare R2 bucket name")
    parser.add_argument("--r2-prefix", default=os.getenv("SIFT_MODEL_R2_PREFIX", ""), help="R2 object key prefix")
    parser.add_argument(
        "--r2-account-id",
        default=os.getenv("CLOUDFLARE_ACCOUNT_ID"),
        help="Cloudflare account id used to derive the R2 S3 endpoint",
    )
    parser.add_argument("--r2-endpoint-url", default=os.getenv("SIFT_MODEL_R2_ENDPOINT_URL"), help="explicit R2 S3 endpoint URL")
    parser.add_argument("--aws-profile", default=os.getenv("AWS_PROFILE"), help="optional AWS CLI profile for R2 credentials")
    parser.add_argument("--aws-region", default=os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION") or "auto")
    parser.add_argument(
        "--upload-command",
        default=None,
        help="optional CLI template run once per uploaded file; placeholders: {src}, {path}, {content_type}, {cache_control}",
    )
    parser.add_argument("--dry-run", action="store_true", help="validate and print upload plan without copying or uploading")
    parser.add_argument("--verify-http", action="store_true", help="HEAD the public manifest/artifact URLs after upload")
    parser.add_argument("--artifact-cache-control", default=DEFAULT_ARTIFACT_CACHE_CONTROL)
    parser.add_argument("--manifest-cache-control", default=DEFAULT_MANIFEST_CACHE_CONTROL)
    parser.add_argument("--write-manifest", action="store_true", help="also update the manifest inside --model-dir")
    parser.add_argument(
        "--env-file",
        type=Path,
        default=None,
        help=f"dotenv file to load before reading SIFT_* / AWS_* variables; defaults to {DEFAULT_DOTENV_NAME} when present",
    )
    parser.add_argument("--no-env-file", action="store_true", help="skip automatic dotenv loading")
    return parser.parse_args(raw)


def load_dotenv_from_arguments(raw: list[str]) -> None:
    if "-h" in raw or "--help" in raw:
        return

    env_file: Path | None = None
    explicit_env_file = False
    skip_env_file = False

    index = 0
    while index < len(raw):
        token = raw[index]
        if token == "--no-env-file":
            skip_env_file = True
        elif token == "--env-file":
            index += 1
            if index >= len(raw):
                raise SystemExit("error: --env-file requires a value")
            env_file = Path(raw[index])
            explicit_env_file = True
        elif token.startswith("--env-file="):
            env_file = Path(token.split("=", 1)[1])
            explicit_env_file = True
        index += 1

    if skip_env_file:
        return

    if env_file is None:
        configured = os.getenv("SIFT_SIGNAL_MODEL_ENV_FILE")
        if configured:
            env_file = Path(configured)
            explicit_env_file = True
        else:
            env_file = repo_root() / DEFAULT_DOTENV_NAME

    if env_file.exists():
        load_dotenv(env_file)
    elif explicit_env_file:
        raise SystemExit(f"error: dotenv file not found: {env_file}")


def repo_root() -> Path:
    directory = Path(__file__).resolve().parent
    while directory != directory.parent:
        if (directory / "package.json").exists() and (directory / "pnpm-workspace.yaml").exists():
            return directory
        directory = directory.parent
    return Path.cwd()


def load_dotenv(path: Path) -> None:
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        try:
            parts = shlex.split(raw_line, comments=True, posix=True)
        except ValueError as error:
            raise SystemExit(f"error: invalid dotenv syntax in {path}:{line_number}: {error}") from error
        if not parts:
            continue
        if parts[0] == "export":
            parts = parts[1:]
        if len(parts) != 1 or "=" not in parts[0]:
            raise SystemExit(f"error: invalid dotenv assignment in {path}:{line_number}")
        key, value = parts[0].split("=", 1)
        key = key.strip()
        if not key or not key.replace("_", "").isalnum() or key[0].isdigit():
            raise SystemExit(f"error: invalid dotenv key in {path}:{line_number}: {key}")
        os.environ.setdefault(key, value)


def main() -> None:
    args = parse_arguments()
    base_url = normalize_base_url(args.base_url)
    model_dir = args.model_dir.expanduser().resolve()
    if not model_dir.is_dir():
        raise SystemExit(f"error: --model-dir is not a directory: {model_dir}")
    if not args.dry_run and args.dest_dir is None and args.upload_command is None and not args.r2_bucket:
        raise SystemExit("error: pass --r2-bucket, --dest-dir, --upload-command, or --dry-run")

    validate_command_template(args.upload_command)
    if args.r2_bucket and not args.dry_run:
        validate_r2_configuration(args)

    manifest_path = model_dir / f"{args.model_name}.manifest.json"
    manifest = read_manifest(manifest_path)
    verify_selected_candidate(args.selection.expanduser().resolve(), manifest, model_dir)
    release_id = args.release_id or require_string(manifest, "version")
    ensure_safe_relative_path(release_id)
    release_prefix = f"releases/{release_id}"
    release_base_url = f"{base_url}/{release_prefix}"
    artifact_base_url = (
        normalize_reused_artifacts_base_url(args.reuse_artifacts_base_url)
        if args.reuse_artifacts_base_url
        else release_base_url
    )
    manifest = normalize_manifest(manifest, model_dir, args.model_name, artifact_base_url)
    validate_manifest_artifacts(manifest, model_dir)
    if args.reuse_artifacts_base_url:
        verify_reused_remote_artifacts(manifest, artifact_base_url)
    signing_key = require_signing_key(args.signing_key, args.signing_key_id)
    manifest["keyID"] = args.signing_key_id
    manifest["signature"] = sign_payload(canonical_release_payload(manifest), signing_key)

    with tempfile.TemporaryDirectory(prefix="sift-model-upload-") as temp:
        staged_manifest = Path(temp) / manifest_path.name
        staged_manifest.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        release_channel = make_channel_manifest(
            manifest=manifest,
            release_id=release_id,
            release_manifest_url=f"{release_base_url}/{manifest_path.name}",
            release_manifest_sha256=file_sha256(staged_manifest),
            key_id=args.signing_key_id,
            signing_key=signing_key,
        )
        channel_entries = [release_channel]
        if not args.no_preserve_channel_history:
            published_entries = load_published_channel_entries(
                f"{base_url}/{args.channel_path}",
                signing_key,
            )
            if args.reuse_artifacts_base_url:
                published_entries = entries_after_metadata_revision(published_entries, release_channel)
            channel_entries.extend(published_entries)
        for compatible_manifest_url in args.compatible_release_manifest_url:
            compatible_entry = channel_entry_from_release_manifest(
                compatible_manifest_url,
                key_id=args.signing_key_id,
                signing_key=signing_key,
            )
            if args.reuse_artifacts_base_url:
                channel_entries = entries_after_metadata_revision(channel_entries, compatible_entry)
            channel_entries.append(compatible_entry)
        channel = make_channel_catalog(
            channel_entries,
            key_id=args.signing_key_id,
            signing_key=signing_key,
        )
        staged_channel = Path(temp) / "channel.json"
        staged_channel.write_text(json.dumps(channel, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

        items = upload_items(
            manifest=manifest,
            model_dir=model_dir,
            staged_manifest=staged_manifest,
            manifest_cache_control=args.manifest_cache_control,
            artifact_cache_control=args.artifact_cache_control,
            release_prefix=release_prefix,
            channel_path=args.channel_path,
            staged_channel=staged_channel,
            include_artifacts=not bool(args.reuse_artifacts_base_url),
        )

        print_channel_summary(channel)
        print_plan(items, base_url)

        if args.write_manifest and not args.dry_run:
            manifest_path.write_text(staged_manifest.read_text(encoding="utf-8"), encoding="utf-8")
            print(f"updated manifest: {manifest_path}")

        if args.dry_run:
            return

        channel_items = [item for item in items if item.path == args.channel_path]
        release_items = [item for item in items if item.path != args.channel_path]
        if len(channel_items) != 1:
            raise SystemExit("error: upload plan must contain exactly one channel pointer")

        if args.dest_dir is not None:
            destination = args.dest_dir.expanduser().resolve()
            copy_to_destination(release_items, destination, immutable=True)

        remote_enabled = bool(args.r2_bucket or args.upload_command is not None)
        pending_release_items = release_items
        if remote_enabled:
            pending_release_items = pending_immutable_remote_items(release_items, base_url)
            upload_remote_items(pending_release_items, args)
            if args.verify_http:
                verify_http(release_items, base_url)

        # Publish the mutable pointer only after every immutable release object
        # is present and, when requested, verified through the public route.
        if args.dest_dir is not None:
            copy_to_destination(channel_items, destination, immutable=False)
        if remote_enabled:
            upload_remote_items(channel_items, args)
            if args.verify_http:
                verify_http(channel_items, base_url)


def normalize_base_url(value: str | None) -> str:
    if not value:
        raise SystemExit("error: pass --base-url or set SIFT_SIGNAL_MODEL_BASE_URL")
    value = value.rstrip("/")
    if not value.startswith(("https://", "http://")):
        raise SystemExit("error: --base-url must be an absolute http(s) URL")
    return value


def normalize_reused_artifacts_base_url(value: str) -> str:
    normalized = normalize_base_url(value)
    if not normalized.startswith("https://"):
        raise SystemExit("error: --reuse-artifacts-base-url must use https")
    return normalized


def entries_after_metadata_revision(
    published_entries: list[dict[str, Any]],
    replacement: dict[str, Any],
) -> list[dict[str, Any]]:
    matches = [
        entry for entry in published_entries
        if entry.get("modelABI") == replacement.get("modelABI")
        and entry.get("releaseSequence") == replacement.get("releaseSequence")
    ]
    if len(matches) != 1:
        raise SystemExit("error: metadata revision must replace exactly one published release")
    current = matches[0]
    boundary_fields = (
        "modelABI",
        "releaseSequence",
        "minimumAppBuild",
        "maximumAppBuild",
        "minimumOSVersion",
        "downloadBytes",
    )
    if any(current.get(field) != replacement.get(field) for field in boundary_fields):
        raise SystemExit("error: metadata revision cannot change release compatibility or download size")
    return [entry for entry in published_entries if entry is not current]


def read_manifest(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise SystemExit(f"error: manifest not found: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(f"error: invalid manifest JSON: {path}: {error}") from error
    if not isinstance(data, dict):
        raise SystemExit(f"error: manifest must be an object: {path}")
    return data


def normalize_manifest(manifest: dict[str, Any], model_dir: Path, model_name: str, base_url: str) -> dict[str, Any]:
    manifest = dict(manifest)
    model_artifact = require_string(manifest, "modelArtifact")
    tokenizer_artifact = require_string(manifest, "tokenizerArtifact")
    if manifest.get("tokenizerKind") != "bpe" or not tokenizer_artifact.endswith(".siftbpe"):
        raise SystemExit("error: tokenizer must be a BPE .siftbpe artifact")

    artifacts = manifest.get("remoteArtifacts")
    if not isinstance(artifacts, list) or not artifacts:
        artifacts = derive_remote_artifacts(model_dir, [model_artifact, tokenizer_artifact])
    else:
        artifacts = normalize_remote_artifacts(model_dir, artifacts)

    remote_paths = {item["path"] for item in artifacts}
    if tokenizer_artifact not in remote_paths:
        raise SystemExit(
            "error: tokenizerArtifact is missing from remoteArtifacts: "
            f"{tokenizer_artifact}"
        )

    manifest["remoteBaseURL"] = base_url
    manifest["remoteArtifacts"] = artifacts
    manifest["downloadBytes"] = sum(int(item.get("byteCount", 0)) for item in artifacts)
    manifest["quantizationProfile"] = normalize_quantization_profile(manifest.get("quantizationProfile"))
    manifest["validationMetrics"] = normalize_validation_metrics(manifest.get("validationMetrics"))

    model_path = model_dir / model_artifact
    if model_path.exists():
        expected = manifest.get("sha256")
        actual = directory_sha256(model_path) if model_path.is_dir() else file_sha256(model_path)
        if expected and expected != actual:
            raise SystemExit(f"error: modelArtifact sha256 mismatch for {model_artifact}: expected {expected}, got {actual}")
        manifest["sha256"] = actual

    manifest.setdefault("modelArtifact", f"{model_name}.mlpackage")
    return manifest


def normalize_validation_metrics(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise SystemExit("error: validationMetrics must be an object")
    missing = [key for key in SIGNED_VALIDATION_METRIC_FIELDS if key not in raw]
    if missing:
        raise SystemExit(f"error: validationMetrics is missing fields: {', '.join(missing)}")

    normalized = {
        key: normalize_manifest_number(raw[key], f"validationMetrics.{key}")
        for key in SIGNED_VALIDATION_METRIC_FIELDS[:-1]
    }
    languages = raw["languageAccuracy"]
    if not isinstance(languages, dict) or not languages:
        raise SystemExit("error: validationMetrics.languageAccuracy must be a non-empty object")
    normalized["languageAccuracy"] = {
        language: normalize_manifest_number(value, f"validationMetrics.languageAccuracy.{language}")
        for language, value in languages.items()
        if isinstance(language, str) and language
    }
    if len(normalized["languageAccuracy"]) != len(languages):
        raise SystemExit("error: validationMetrics.languageAccuracy keys must be non-empty strings")
    return normalized


def normalize_quantization_profile(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise SystemExit("error: quantizationProfile must be an object")
    required = SIGNED_QUANTIZATION_PROFILE_FIELDS[:-1]
    missing = [key for key in required if key not in raw]
    if missing:
        raise SystemExit(f"error: quantizationProfile is missing fields: {', '.join(missing)}")
    return {
        key: raw[key]
        for key in SIGNED_QUANTIZATION_PROFILE_FIELDS
        if key in raw and raw[key] is not None
    }


def normalize_manifest_number(raw: Any, field: str) -> int | float:
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        raise SystemExit(f"error: {field} must be numeric")
    value = float(raw)
    if not math.isfinite(value):
        raise SystemExit(f"error: {field} must be finite")
    return int(value) if value.is_integer() else value


def derive_remote_artifacts(model_dir: Path, relative_paths: list[str]) -> list[dict[str, Any]]:
    artifacts: list[dict[str, Any]] = []
    for relative_path in relative_paths:
        ensure_safe_relative_path(relative_path)
        root = model_dir / relative_path
        if not root.exists():
            raise SystemExit(f"error: artifact missing: {root}")
        files = sorted(path for path in root.rglob("*") if path.is_file()) if root.is_dir() else [root]
        for file in files:
            path = file.relative_to(model_dir).as_posix()
            artifacts.append({
                "path": path,
                "sha256": file_sha256(file),
                "byteCount": file.stat().st_size,
            })
    return sorted(artifacts, key=lambda item: item["path"])


def normalize_remote_artifacts(model_dir: Path, artifacts: list[Any]) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for raw in artifacts:
        if not isinstance(raw, dict):
            raise SystemExit("error: remoteArtifacts entries must be objects")
        path = raw.get("path")
        if not isinstance(path, str):
            raise SystemExit("error: remoteArtifacts entry missing string path")
        ensure_safe_relative_path(path)
        file = model_dir / path
        if not file.is_file():
            raise SystemExit(f"error: remote artifact missing: {file}")
        checksum = raw.get("sha256") if isinstance(raw.get("sha256"), str) else file_sha256(file)
        byte_count = raw.get("byteCount") if isinstance(raw.get("byteCount"), int) else file.stat().st_size
        normalized.append({"path": path, "sha256": checksum, "byteCount": byte_count})
    return sorted(normalized, key=lambda item: item["path"])


def validate_manifest_artifacts(manifest: dict[str, Any], model_dir: Path) -> None:
    for item in manifest["remoteArtifacts"]:
        path = item["path"]
        file = model_dir / path
        actual = file_sha256(file)
        if item.get("sha256") != actual:
            raise SystemExit(f"error: remote artifact checksum mismatch: {path}")
        if item.get("byteCount") != file.stat().st_size:
            raise SystemExit(f"error: remote artifact byte count mismatch: {path}")


def verify_selected_candidate(selection_path: Path, manifest: dict[str, Any], model_dir: Path) -> None:
    if not selection_path.exists():
        raise SystemExit(f"error: selected candidate file not found: {selection_path}")
    selection = read_manifest(selection_path)
    if selection.get("schemaVersion") != 1:
        raise SystemExit("error: unsupported selected candidate schema")
    selected_sha = selection.get("artifactSHA256")
    manifest_sha = manifest.get("sha256")
    profile_id = manifest.get("quantizationProfile", {}).get("identifier")
    if selected_sha != manifest_sha:
        raise SystemExit(
            "error: refusing to upload a candidate that is not selected: "
            f"selected={selected_sha}, manifest={manifest_sha}"
        )
    if selection.get("profileID") != profile_id:
        raise SystemExit("error: selected candidate profile does not match manifest")
    report_path = Path(str(selection.get("reportPath", "")))
    if not report_path.is_absolute():
        report_path = (selection_path.parent / report_path).resolve()
    if not report_path.is_file() or file_sha256(report_path) != selection.get("reportSHA256"):
        raise SystemExit("error: selected candidate report is missing or has changed")
    report = read_manifest(report_path)
    if report.get("profileID") != selection.get("profileID"):
        raise SystemExit("error: selected candidate report profile does not match selection")
    if report.get("artifactSHA256") != selected_sha:
        raise SystemExit("error: selected candidate report artifact does not match selection")
    if report.get("downloadBytes") != manifest.get("downloadBytes"):
        raise SystemExit("error: selected candidate report download size does not match manifest")
    metrics = report.get("metrics", {})
    actions = report.get("messageFilterActions", {})
    device = report.get("deviceMetrics", {})
    if device.get("runtimeExecutionVerified") is not True:
        raise SystemExit("error: candidate lacks matching CPU or accelerator execution evidence")
    if device.get("peakPhysicalFootprintIncreaseBytes", float("inf")) > 256 * 1024 * 1024:
        raise SystemExit("error: release-device peak memory increase gate failed")
    if device.get("averagePhysicalFootprintIncreaseBytes", float("inf")) > 256 * 1024 * 1024:
        raise SystemExit("error: release-device average memory increase gate failed")
    if (
        device.get("p95LatencyMilliseconds", float("inf")) > 150
        or device.get("p99LatencyMilliseconds", float("inf")) > 250
    ):
        raise SystemExit("error: release-device runtime latency gate failed")
    if actions.get("rulesOverrideRate", 0) < 1.0:
        raise SystemExit("error: MessageFilter rules override gate failed")
    if metrics.get("fixedAccuracy", 0) < 0.99:
        raise SystemExit("error: fixed accuracy gate failed")
    if metrics.get("promotionAccuracy", 0) < 0.98:
        raise SystemExit("error: promotion accuracy gate failed")
    if metrics.get("billingAccuracy", 0) < 0.90 or metrics.get("billingActionAccuracy", 0) < 0.95:
        raise SystemExit("error: billing boundary gate failed")
    if metrics.get("fp16Top1Agreement", 0) < 0.985:
        raise SystemExit("error: FP16 top-1 agreement gate failed")
    if metrics.get("probabilitiesFinite") is not True or metrics.get("probabilitySumsValid") is not True:
        raise SystemExit("error: probability validity gate failed")
    if (
        actions.get("fixedAccuracy", 0) < 0.99
        or actions.get("promotionAccuracy", 0) < 0.98
        or actions.get("billingAccuracy", 0) < 0.95
    ):
        raise SystemExit("error: MessageFilter action accuracy gate failed")
    if actions.get("benignOrTransactionToJunk", 1) != 0:
        raise SystemExit("error: MessageFilter benign/transaction junk gate failed")
    if actions.get("promotionFalsePositiveRate", 1) > 0.01:
        raise SystemExit("error: MessageFilter promotion false-positive gate failed")
    if actions.get("scamJunkRecall", 0) < 1.0:
        raise SystemExit("error: MessageFilter scam recall gate failed")
    if (
        device.get("extensionColdP95Milliseconds", float("inf")) > 750
        or device.get("extensionColdP99Milliseconds", float("inf")) > 900
        or device.get("extensionColdMaximumMilliseconds", float("inf")) >= 1000
        or device.get("extensionWarmP95Milliseconds", float("inf")) > 150
        or device.get("extensionWarmP99Milliseconds", float("inf")) > 250
        or (
            device.get("computeUnits") != "cpuOnly"
            and device.get("contentionFallbackP99Milliseconds", float("inf")) > 600
        )
    ):
        raise SystemExit("error: MessageFilter device latency gate failed")
    if device.get("jetsamCount", 1) != 0:
        raise SystemExit("error: MessageFilter jetsam gate failed")
    if (
        device.get("memoryDriftBytes", float("inf")) > 16 * 1024 * 1024
        or device.get("memoryDriftFraction", float("inf")) > 0.10
    ):
        raise SystemExit("error: MessageFilter memory drift gate failed")
    if device.get("stressConditionsPassed") is not True:
        raise SystemExit("error: MessageFilter stress-condition gate failed")
    if not model_dir.is_dir():
        raise SystemExit(f"error: candidate directory is not a directory: {model_dir}")


def canonical_release_payload(manifest: dict[str, Any]) -> bytes:
    fields = (
        "schemaVersion", "releaseSequence", "modelABI", "minimumAppBuild", "maximumAppBuild",
        "minimumOSVersion", "runtimeProfile", "quantizationProfile", "validationMetrics",
        "version", "trainedAt", "algorithm", "backbone", "languages", "labels",
        "maxSequenceLength", "doLowerCase", "tokenizerKind", "tokenizerArtifact",
        "modelArtifact", "sha256", "taxonomyHash", "tokenizerSHA256", "keyID",
        "remoteBaseURL", "remoteArtifacts", "downloadBytes",
    )
    payload = {key: manifest[key] for key in fields if key in manifest}
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def canonical_channel_payload(channel: dict[str, Any]) -> bytes:
    fields = (
        "schemaVersion", "releaseSequence", "releaseID", "releaseManifestURL",
        "releaseManifestSHA256", "modelABI", "minimumAppBuild", "maximumAppBuild",
        "minimumOSVersion", "downloadBytes", "keyID",
    )
    payload = {key: channel[key] for key in fields if key in channel}
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def canonical_catalog_payload(channel: dict[str, Any]) -> bytes:
    releases = channel.get("compatibleReleases")
    if not isinstance(releases, list) or not releases:
        raise SystemExit("error: compatibility catalog must contain at least one release")
    payload = {
        "compatibleReleases": [channel_release_entry(release) for release in releases],
    }
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def channel_release_entry(channel: dict[str, Any]) -> dict[str, Any]:
    fields = (
        "schemaVersion", "releaseSequence", "releaseID", "releaseManifestURL",
        "releaseManifestSHA256", "modelABI", "minimumAppBuild", "maximumAppBuild",
        "minimumOSVersion", "downloadBytes", "keyID", "signature",
    )
    entry = {key: channel[key] for key in fields if key in channel}
    missing = [key for key in fields if key not in entry]
    if missing:
        raise SystemExit(f"error: channel release entry is missing fields: {', '.join(missing)}")
    return entry


def require_signing_key(path: Path | None, key_id: str | None) -> Path:
    if path is None or not key_id:
        raise SystemExit("error: --signing-key and --signing-key-id are required for v2 model releases")
    resolved = Path(path).expanduser().resolve()
    if not resolved.exists():
        raise SystemExit(f"error: signing key not found: {resolved}")
    return resolved


def sign_payload(payload: bytes, signing_key: Path) -> str:
    # Apple's OpenSSL/LibreSSL pkeyutl requires a seekable input for Ed25519
    # one-shot operations; stdin fails with "unable to determine file size".
    with tempfile.NamedTemporaryFile(prefix="sift-manifest-payload-") as source:
        source.write(payload)
        source.flush()
        result = subprocess.run(
            [
                "openssl", "pkeyutl", "-sign", "-inkey", str(signing_key),
                "-rawin", "-in", source.name,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    if result.returncode != 0:
        raise SystemExit(f"error: Ed25519 signing failed: {result.stderr.decode(errors='replace').strip()}")
    return base64.b64encode(result.stdout).decode("ascii")


def make_channel_manifest(
    manifest: dict[str, Any],
    release_id: str,
    release_manifest_url: str,
    release_manifest_sha256: str,
    key_id: str,
    signing_key: Path,
) -> dict[str, Any]:
    channel = {
        "schemaVersion": 2,
        "releaseSequence": manifest["releaseSequence"],
        "releaseID": release_id,
        "releaseManifestURL": release_manifest_url,
        "releaseManifestSHA256": release_manifest_sha256,
        "modelABI": manifest["modelABI"],
        "minimumAppBuild": manifest["minimumAppBuild"],
        "maximumAppBuild": manifest["maximumAppBuild"],
        "minimumOSVersion": manifest["minimumOSVersion"],
        "downloadBytes": manifest["downloadBytes"],
        "keyID": key_id,
    }
    channel["signature"] = sign_payload(canonical_channel_payload(channel), signing_key)
    return channel


def make_channel_catalog(
    entries: list[dict[str, Any]],
    key_id: str,
    signing_key: Path,
) -> dict[str, Any]:
    releases = merge_channel_entries(entries)
    if not releases:
        raise SystemExit("error: compatibility catalog has no releases")
    oldest_supported_build = min(int(entry["minimumAppBuild"]) for entry in releases)
    legacy_candidates = [
        entry for entry in releases
        if int(entry["minimumAppBuild"]) <= oldest_supported_build <= int(entry["maximumAppBuild"])
    ]
    legacy = max(legacy_candidates, key=lambda entry: int(entry["releaseSequence"]))
    channel = dict(legacy)
    channel["compatibleReleases"] = releases
    channel["catalogKeyID"] = key_id
    channel["catalogSignature"] = sign_payload(canonical_catalog_payload(channel), signing_key)
    return channel


def merge_channel_entries(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    merged: dict[tuple[str, int], dict[str, Any]] = {}
    for raw in entries:
        entry = channel_release_entry(raw)
        key = (require_string(entry, "modelABI"), int(entry["releaseSequence"]))
        existing = merged.get(key)
        if existing is not None and existing != entry:
            raise SystemExit(
                "error: channel history contains different releases for "
                f"modelABI={key[0]} releaseSequence={key[1]}"
            )
        merged[key] = entry
    return sorted(merged.values(), key=lambda entry: (int(entry["releaseSequence"]), entry["modelABI"]))


def signature_matches(payload: bytes, signature: Any, signing_key: Path) -> bool:
    return isinstance(signature, str) and signature == sign_payload(payload, signing_key)


def verified_channel_entries(channel: dict[str, Any], signing_key: Path) -> list[dict[str, Any]]:
    if not signature_matches(canonical_channel_payload(channel), channel.get("signature"), signing_key):
        raise SystemExit("error: published channel signature does not match the configured signing key")
    releases = channel.get("compatibleReleases")
    if releases is None:
        return [channel_release_entry(channel)]
    if not isinstance(releases, list) or not releases:
        raise SystemExit("error: published compatibility catalog is invalid")
    entries = [channel_release_entry(release) for release in releases]
    for entry in entries:
        if not signature_matches(canonical_channel_payload(entry), entry.get("signature"), signing_key):
            raise SystemExit("error: published compatibility release signature is invalid")
    if channel_release_entry(channel) not in entries:
        raise SystemExit("error: published compatibility catalog omits its legacy channel release")
    catalog = dict(channel)
    catalog["compatibleReleases"] = entries
    if not signature_matches(canonical_catalog_payload(catalog), channel.get("catalogSignature"), signing_key):
        raise SystemExit("error: published compatibility catalog signature is invalid")
    return entries


def load_published_channel_entries(url: str, signing_key: Path) -> list[dict[str, Any]]:
    request = publisher_request(url)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status < 200 or response.status >= 300:
                raise SystemExit(f"error: {url} returned HTTP {response.status}")
            data = response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return []
        raise SystemExit(f"error: {url} returned HTTP {error.code}") from error
    try:
        channel = json.loads(data)
    except json.JSONDecodeError as error:
        raise SystemExit(f"error: invalid published channel JSON: {url}: {error}") from error
    if not isinstance(channel, dict):
        raise SystemExit(f"error: published channel must be an object: {url}")
    return verified_channel_entries(channel, signing_key)


def channel_entry_from_release_manifest(
    url: str,
    key_id: str,
    signing_key: Path,
) -> dict[str, Any]:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https":
        raise SystemExit("error: compatible release manifest URL must use https")
    request = publisher_request(url)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status < 200 or response.status >= 300:
                raise SystemExit(f"error: {url} returned HTTP {response.status}")
            data = response.read()
    except urllib.error.HTTPError as error:
        raise SystemExit(f"error: {url} returned HTTP {error.code}") from error
    try:
        manifest = json.loads(data)
    except json.JSONDecodeError as error:
        raise SystemExit(f"error: invalid compatible release manifest JSON: {url}: {error}") from error
    if not isinstance(manifest, dict):
        raise SystemExit(f"error: compatible release manifest must be an object: {url}")
    if manifest.get("keyID") != key_id:
        raise SystemExit(f"error: compatible release uses a different signing key: {url}")
    if not signature_matches(canonical_release_payload(manifest), manifest.get("signature"), signing_key):
        raise SystemExit(f"error: compatible release signature is invalid: {url}")
    release_id = Path(parsed.path).parent.name
    return make_channel_manifest(
        manifest=manifest,
        release_id=release_id,
        release_manifest_url=url,
        release_manifest_sha256=hashlib.sha256(data).hexdigest(),
        key_id=key_id,
        signing_key=signing_key,
    )


def upload_items(
    manifest: dict[str, Any],
    model_dir: Path,
    staged_manifest: Path,
    manifest_cache_control: str,
    artifact_cache_control: str,
    release_prefix: str = "",
    channel_path: str | None = None,
    staged_channel: Path | None = None,
    include_artifacts: bool = True,
) -> list[UploadItem]:
    prefix = f"{release_prefix}/" if release_prefix else ""
    items = [
        UploadItem(
            source=staged_manifest,
            path=f"{prefix}{staged_manifest.name}",
            content_type="application/json",
            cache_control=manifest_cache_control,
        )
    ]
    if include_artifacts:
        for artifact in manifest["remoteArtifacts"]:
            path = artifact["path"]
            items.append(UploadItem(
                source=model_dir / path,
                path=f"{prefix}{path}",
                content_type=content_type_for(path),
                cache_control=artifact_cache_control,
            ))
    if channel_path and staged_channel:
        items.append(UploadItem(
            source=staged_channel,
            path=channel_path,
            content_type="application/json",
            cache_control=manifest_cache_control,
        ))
    return items


def content_type_for(path: str) -> str:
    if path.endswith(".json"):
        return "application/json"
    if path.endswith(".txt"):
        return "text/plain; charset=utf-8"
    return mimetypes.guess_type(path)[0] or "application/octet-stream"


def print_plan(items: list[UploadItem], base_url: str) -> None:
    total_bytes = sum(item.source.stat().st_size for item in items)
    print(f"upload files: {len(items)}")
    print(f"upload bytes: {total_bytes:,}")
    print(f"manifest URL: {base_url}/{items[0].path}")
    for item in items:
        print(f"  {item.path} <- {item.source} ({item.source.stat().st_size:,} bytes)")


def print_channel_summary(channel: dict[str, Any]) -> None:
    releases = channel.get("compatibleReleases", [channel])
    summary = ", ".join(
        f"seq {entry['releaseSequence']} (build {entry['minimumAppBuild']}...{entry['maximumAppBuild']})"
        for entry in releases
    )
    print(
        "legacy channel release: "
        f"seq {channel['releaseSequence']} ({channel['releaseID']})"
    )
    print(f"signed compatibility releases: {summary}")


def copy_to_destination(items: list[UploadItem], dest_dir: Path, *, immutable: bool) -> None:
    for item in items:
        target = dest_dir / item.path
        target.parent.mkdir(parents=True, exist_ok=True)
        if immutable and target.exists():
            if file_sha256(target) != file_sha256(item.source):
                raise SystemExit(f"error: immutable destination already contains different bytes: {target}")
            print(f"already published: {target}")
            continue
        shutil.copy2(item.source, target)
        print(f"copied: {target}")


def upload_remote_items(items: list[UploadItem], args: argparse.Namespace) -> None:
    if args.r2_bucket:
        upload_to_r2(items, args)
    if args.upload_command is not None:
        run_upload_command(items, args.upload_command)


def public_object_digest(url: str) -> tuple[str, int] | None:
    request = publisher_request(url)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            if response.status < 200 or response.status >= 300:
                raise SystemExit(f"error: {url} returned HTTP {response.status}")
            digest = hashlib.sha256()
            byte_count = 0
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                byte_count += len(chunk)
            return digest.hexdigest(), byte_count
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise SystemExit(f"error: {url} returned HTTP {error.code}") from error


def publisher_request(url: str) -> urllib.request.Request:
    return urllib.request.Request(
        url,
        headers={
            "User-Agent": "SiftModelPublisher/1.0 (+https://sift.alkinum.io)",
            "Cache-Control": "no-cache",
        },
    )


def pending_immutable_remote_items(items: list[UploadItem], base_url: str) -> list[UploadItem]:
    pending: list[UploadItem] = []
    for item in items:
        url = f"{base_url}/{item.path}"
        remote = public_object_digest(url)
        if remote is None:
            pending.append(item)
            continue
        expected = (file_sha256(item.source), item.source.stat().st_size)
        if remote != expected:
            raise SystemExit(f"error: immutable model URL already contains different bytes: {url}")
        print(f"already published: {url}")
    return pending


def verify_reused_remote_artifacts(manifest: dict[str, Any], artifact_base_url: str) -> None:
    for artifact in manifest["remoteArtifacts"]:
        path = artifact["path"]
        url = f"{artifact_base_url}/{urllib.parse.quote(path, safe='/')}"
        remote = public_object_digest(url)
        expected = (artifact["sha256"], artifact["byteCount"])
        if remote != expected:
            raise SystemExit(f"error: reused model artifact does not match signed metadata: {url}")
        print(f"verified reused artifact: {url}")


def validate_r2_configuration(args: argparse.Namespace) -> None:
    if shutil.which("aws") is None:
        raise SystemExit("error: --r2-bucket requires the AWS CLI (`aws`) to be installed")
    r2_endpoint_url(args)
    if args.aws_profile:
        return
    if os.getenv("AWS_ACCESS_KEY_ID") and os.getenv("AWS_SECRET_ACCESS_KEY"):
        return
    raise SystemExit("error: set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or pass --aws-profile for R2 upload")


def r2_endpoint_url(args: argparse.Namespace) -> str:
    if args.r2_endpoint_url:
        return args.r2_endpoint_url.rstrip("/")
    if args.r2_account_id:
        return f"https://{args.r2_account_id}.r2.cloudflarestorage.com"
    raise SystemExit("error: set CLOUDFLARE_ACCOUNT_ID or pass --r2-endpoint-url for R2 upload")


def r2_object_key(prefix: str, path: str) -> str:
    prefix = prefix.strip("/")
    return f"{prefix}/{path}" if prefix else path


def upload_to_r2(items: list[UploadItem], args: argparse.Namespace) -> None:
    endpoint = r2_endpoint_url(args)
    for item in items:
        target = f"s3://{args.r2_bucket}/{r2_object_key(args.r2_prefix, item.path)}"
        command = [
            "aws", "s3", "cp",
            str(item.source),
            target,
            "--endpoint-url", endpoint,
            "--region", args.aws_region,
            "--content-type", item.content_type,
            "--cache-control", item.cache_control,
        ]
        if args.aws_profile:
            command.extend(["--profile", args.aws_profile])
        print(f"r2 upload: {' '.join(shlex.quote(part) for part in command)}")
        subprocess.run(command, check=True)


def run_upload_command(items: list[UploadItem], template: str) -> None:
    for item in items:
        command = [
            part.format(
                src=str(item.source),
                path=item.path,
                content_type=item.content_type,
                cache_control=item.cache_control,
            )
            for part in shlex.split(template)
        ]
        print(f"upload: {' '.join(shlex.quote(part) for part in command)}")
        subprocess.run(command, check=True)


def verify_http(items: list[UploadItem], base_url: str) -> None:
    for item in items:
        url = f"{base_url}/{item.path}"
        remote = public_object_digest(url)
        expected = (file_sha256(item.source), item.source.stat().st_size)
        if remote is None:
            raise SystemExit(f"error: {url} returned HTTP 404")
        if remote != expected:
            raise SystemExit(f"error: public object bytes do not match upload: {url}")
        print(f"verified: {url}")


def validate_command_template(template: str | None) -> None:
    if template is None:
        return
    allowed = {"src", "path", "content_type", "cache_control"}
    for _, name, _, _ in Formatter().parse(template):
        if name is not None and name not in allowed:
            raise SystemExit(f"error: unknown --upload-command placeholder: {name}")


def require_string(manifest: dict[str, Any], key: str) -> str:
    value = manifest.get(key)
    if not isinstance(value, str) or not value:
        raise SystemExit(f"error: manifest missing string {key}")
    return value


def ensure_safe_relative_path(path: str) -> None:
    parts = path.split("/")
    if not path or path.startswith("/") or "." in parts or ".." in parts:
        raise SystemExit(f"error: unsafe relative artifact path: {path}")


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def directory_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    for file in sorted(item for item in path.rglob("*") if item.is_file()):
        digest.update(file.relative_to(path).as_posix().encode("utf-8"))
        digest.update(file.read_bytes())
    return digest.hexdigest()


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
