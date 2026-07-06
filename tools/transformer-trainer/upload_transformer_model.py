#!/usr/bin/env python3
"""Validate and upload a Sift transformer Core ML release.

The app downloads `SiftTransformerClassifier.manifest.json` first, then each
file listed in `remoteArtifacts`. `.mlpackage` is a directory package, so the
manifest lists the package's files individually instead of uploading a zip.

Examples:

  # Dry-run a freshly trained model.
  python3 tools/transformer-trainer/upload_transformer_model.py \
    --model-dir build/pipeline/transformer-model \
    --base-url https://sift.alkinum.io/models \
    --dry-run

  # Copy into a local static/CDN publish directory.
  python3 tools/transformer-trainer/upload_transformer_model.py \
    --model-dir build/pipeline/transformer-model \
    --base-url https://sift.alkinum.io/models \
    --dest-dir /tmp/sift-models

  # Use an object-storage CLI. The template is split with shlex and supports
  # {src}, {path}, {content_type}, and {cache_control}.
  python3 tools/transformer-trainer/upload_transformer_model.py \
    --model-dir build/pipeline/transformer-model \
    --base-url https://sift.alkinum.io/models \
    --upload-command 'rclone copyto {src} r2:sift-public/models/{path}'
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from string import Formatter
from typing import Any


DEFAULT_MODEL_NAME = "SiftTransformerClassifier"
DEFAULT_ARTIFACT_CACHE_CONTROL = "public, max-age=31536000, immutable"
DEFAULT_MANIFEST_CACHE_CONTROL = "public, max-age=300"


@dataclass(frozen=True)
class UploadItem:
    source: Path
    path: str
    content_type: str
    cache_control: str


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model-dir", type=Path, required=True, help="directory containing the exported transformer artifacts")
    parser.add_argument("--model-name", default=DEFAULT_MODEL_NAME)
    parser.add_argument("--base-url", required=True, help="public URL prefix used by the iOS app, e.g. https://sift.alkinum.io/models")
    parser.add_argument("--dest-dir", type=Path, default=None, help="optional local destination directory")
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
    raw = sys.argv[1:]
    if raw and raw[0] == "--":
        raw = raw[1:]
    return parser.parse_args(raw)


def main() -> None:
    args = parse_arguments()
    model_dir = args.model_dir.expanduser().resolve()
    if not model_dir.is_dir():
        raise SystemExit(f"error: --model-dir is not a directory: {model_dir}")
    if not args.dry_run and args.dest_dir is None and args.upload_command is None:
        raise SystemExit("error: pass --dest-dir, --upload-command, or --dry-run")

    validate_command_template(args.upload_command)

    manifest_path = model_dir / f"{args.model_name}.manifest.json"
    manifest = read_manifest(manifest_path)
    manifest = normalize_manifest(manifest, model_dir, args.model_name, args.base_url.rstrip("/"))
    validate_manifest_artifacts(manifest, model_dir)

    with tempfile.TemporaryDirectory(prefix="sift-model-upload-") as temp:
        staged_manifest = Path(temp) / manifest_path.name
        staged_manifest.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

        items = upload_items(
            manifest=manifest,
            model_dir=model_dir,
            staged_manifest=staged_manifest,
            manifest_cache_control=args.manifest_cache_control,
            artifact_cache_control=args.artifact_cache_control,
        )

        print_plan(items, args.base_url.rstrip("/"))

        if args.write_manifest and not args.dry_run:
            manifest_path.write_text(staged_manifest.read_text(encoding="utf-8"), encoding="utf-8")
            print(f"updated manifest: {manifest_path}")

        if args.dry_run:
            return

        if args.dest_dir is not None:
            copy_to_destination(items, args.dest_dir.expanduser().resolve())
        if args.upload_command is not None:
            run_upload_command(items, args.upload_command)
        if args.verify_http:
            verify_http(items, args.base_url.rstrip("/"))


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
    tokenizer_artifact = manifest.get("tokenizerArtifact") or manifest.get("vocabularyArtifact")
    if not isinstance(tokenizer_artifact, str) or not tokenizer_artifact:
        raise SystemExit("error: manifest needs tokenizerArtifact or vocabularyArtifact")

    artifacts = manifest.get("remoteArtifacts")
    if not isinstance(artifacts, list) or not artifacts:
        artifacts = derive_remote_artifacts(model_dir, [model_artifact, tokenizer_artifact])
    else:
        artifacts = normalize_remote_artifacts(model_dir, artifacts)

    manifest["remoteBaseURL"] = base_url
    manifest["remoteArtifacts"] = artifacts
    manifest["downloadBytes"] = sum(int(item.get("byteCount", 0)) for item in artifacts)

    model_path = model_dir / model_artifact
    if model_path.exists():
        expected = manifest.get("sha256")
        actual = directory_sha256(model_path) if model_path.is_dir() else file_sha256(model_path)
        if expected and expected != actual:
            raise SystemExit(f"error: modelArtifact sha256 mismatch for {model_artifact}: expected {expected}, got {actual}")
        manifest["sha256"] = actual

    manifest.setdefault("modelArtifact", f"{model_name}.mlpackage")
    return manifest


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


def upload_items(
    manifest: dict[str, Any],
    model_dir: Path,
    staged_manifest: Path,
    manifest_cache_control: str,
    artifact_cache_control: str,
) -> list[UploadItem]:
    items = [
        UploadItem(
            source=staged_manifest,
            path=staged_manifest.name,
            content_type="application/json",
            cache_control=manifest_cache_control,
        )
    ]
    for artifact in manifest["remoteArtifacts"]:
        path = artifact["path"]
        items.append(UploadItem(
            source=model_dir / path,
            path=path,
            content_type=content_type_for(path),
            cache_control=artifact_cache_control,
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


def copy_to_destination(items: list[UploadItem], dest_dir: Path) -> None:
    for item in items:
        target = dest_dir / item.path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item.source, target)
        print(f"copied: {target}")


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
        request = urllib.request.Request(url, method="HEAD")
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                if response.status < 200 or response.status >= 300:
                    raise SystemExit(f"error: {url} returned HTTP {response.status}")
        except urllib.error.HTTPError as error:
            raise SystemExit(f"error: {url} returned HTTP {error.code}") from error
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
