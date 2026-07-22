#!/usr/bin/env python3
"""Publish an accepted built-in model bundle and atomically update its lock."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "apps/ios/BuiltinModels.lock.json"
PACKAGE_SCRIPT = ROOT / "tools/package_ios_builtin_models.sh"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_directory(path: Path) -> str:
    digest = hashlib.sha256()
    for item in sorted(item for item in path.rglob("*") if item.is_file()):
        digest.update(str(item.relative_to(path)).encode())
        digest.update(item.read_bytes())
    return digest.hexdigest()


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"error: cannot read JSON {path}: {error}") from error


def atomic_write_json(path: Path, value: dict) -> None:
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as handle:
            temporary_path = Path(handle.name)
            json.dump(value, handle, indent=2)
            handle.write("\n")
        os.replace(temporary_path, path)
    finally:
        if temporary_path and temporary_path.exists():
            temporary_path.unlink()


def fail_if_wrong_artifact(manifest: dict, name: str, key: str) -> None:
    if manifest.get(key) != name:
        raise SystemExit(
            f"error: {name} manifest has {key}={manifest.get(key)!r}; expected {name}"
        )


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9._-]+", "-", value.lower()).strip("-.")
    if not slug:
        raise SystemExit("error: release produces an empty URL slug")
    return slug


def public_sha256(url: str) -> str:
    with tempfile.TemporaryDirectory(prefix="sift-ios-public-download-") as temporary:
        downloaded = Path(temporary) / "model-bundle.zip"
        subprocess.run(
            [
                "curl",
                "--fail",
                "--location",
                "--silent",
                "--show-error",
                "--retry",
                "3",
                "--retry-all-errors",
                "--output",
                str(downloaded),
                url,
            ],
            check=True,
        )
        return sha256_file(downloaded)


def public_status(url: str) -> int:
    response = subprocess.run(
        [
            "curl",
            "--location",
            "--silent",
            "--show-error",
            "--head",
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_code}",
            url,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return int(response.stdout.strip() or "0")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models-dir", type=Path, default=ROOT / "apps/ios/GeneratedModels")
    parser.add_argument("--release", help="release label; defaults to classic+pii manifest versions")
    parser.add_argument("--dry-run", action="store_true", help="build and validate without upload or lock update")
    arguments = parser.parse_args()

    models_dir = arguments.models_dir.expanduser().resolve()
    classic_model = models_dir / "SiftSMSClassifier.mlmodel"
    classic_manifest_path = models_dir / "SiftSMSClassifier.manifest.json"
    pii_package = models_dir / "SiftPIIDetector.mlpackage"
    pii_vocabulary = models_dir / "SiftPIIDetector.vocab.txt"
    pii_manifest_path = models_dir / "SiftPIIDetector.manifest.json"
    required = [classic_model, classic_manifest_path, pii_package, pii_vocabulary, pii_manifest_path]
    missing = [str(path) for path in required if not path.exists()]
    if missing:
        raise SystemExit(f"error: missing model artifacts: {', '.join(missing)}")

    classic_manifest = read_json(classic_manifest_path)
    pii_manifest = read_json(pii_manifest_path)
    fail_if_wrong_artifact(classic_manifest, "SiftSMSClassifier.mlmodel", "modelArtifact")
    fail_if_wrong_artifact(pii_manifest, "SiftPIIDetector.mlpackage", "modelArtifact")
    fail_if_wrong_artifact(pii_manifest, "SiftPIIDetector.vocab.txt", "vocabularyArtifact")

    classic_version = str(classic_manifest.get("version", "")).strip()
    pii_version = str(pii_manifest.get("version", "")).strip()
    if not classic_version or not pii_version:
        raise SystemExit("error: both model manifests must contain a non-empty version")
    release = arguments.release or f"{classic_version}+{pii_version}"
    slug = slugify(release)
    archive_url = f"https://sift.alkinum.io/models/releases/ios-builtins/{slug}.zip"

    candidate_lock = {
        "schemaVersion": 1,
        "release": release,
        "archive": {"url": archive_url, "sha256": "0" * 64},
        "classic": {
            "version": classic_version,
            "modelSHA256": sha256_file(classic_model),
            "manifestSHA256": sha256_file(classic_manifest_path),
        },
        "pii": {
            "version": pii_version,
            "packageSHA256": sha256_directory(pii_package),
            "vocabularySHA256": sha256_file(pii_vocabulary),
            "manifestSHA256": sha256_file(pii_manifest_path),
        },
    }

    current_lock = read_json(LOCK_PATH)
    if (
        current_lock.get("classic", {}).get("version") == classic_version
        and current_lock.get("classic", {}).get("modelSHA256")
        != candidate_lock["classic"]["modelSHA256"]
    ):
        raise SystemExit("error: Classic model changed without a manifest version bump")
    if (
        current_lock.get("pii", {}).get("version") == pii_version
        and any(
            current_lock.get("pii", {}).get(key) != candidate_lock["pii"][key]
            for key in ("packageSHA256", "vocabularySHA256", "manifestSHA256")
        )
    ):
        raise SystemExit("error: PII artifacts changed without a manifest version bump")

    archive_path = ROOT / "build/ios-models" / f"SiftBuiltinModels-{release}.zip"

    with tempfile.TemporaryDirectory(prefix="sift-ios-model-publish-") as temporary:
        temporary_path = Path(temporary)
        candidate_lock_path = temporary_path / "BuiltinModels.lock.json"
        candidate_lock_path.write_text(json.dumps(candidate_lock, indent=2) + "\n")
        subprocess.run(
            [
                str(PACKAGE_SCRIPT),
                "--models-dir",
                str(models_dir),
                "--lock-file",
                str(candidate_lock_path),
                "--output",
                str(archive_path),
            ],
            check=True,
            cwd=ROOT,
        )
        archive_sha = sha256_file(archive_path)
        candidate_lock["archive"]["sha256"] = archive_sha
        candidate_lock_path.write_text(json.dumps(candidate_lock, indent=2) + "\n")
        subprocess.run(
            [
                str(ROOT / "tools/verify_ios_builtin_models.sh"),
                "--models-dir",
                str(models_dir),
                "--lock-file",
                str(candidate_lock_path),
            ],
            check=True,
            cwd=ROOT,
        )

        print(f"release: {release}")
        print(f"archive: {archive_path}")
        print(f"url: {archive_url}")
        print(f"sha256: {archive_sha}")
        if arguments.dry_run:
            print("dry-run: R2 upload and lock update skipped")
            return 0

        lock_diff = subprocess.run(
            ["git", "diff", "--quiet", "HEAD", "--", str(LOCK_PATH.relative_to(ROOT))],
            cwd=ROOT,
            check=False,
        )
        if lock_diff.returncode != 0:
            raise SystemExit("error: commit or revert local BuiltinModels.lock.json changes before publishing")

        status = public_status(archive_url)
        if 200 <= status < 400:
            if public_sha256(archive_url) != archive_sha:
                raise SystemExit(f"error: immutable model URL already contains different bytes: {archive_url}")
            print("R2 object already contains the candidate archive; resuming publication.")
        elif status == 404:
            subprocess.run(
                [
                    "pnpm",
                    "exec",
                    "wrangler",
                    "r2",
                    "object",
                    "put",
                    f"sift-models/models/releases/ios-builtins/{slug}.zip",
                    "--file",
                    str(archive_path),
                    "--content-type",
                    "application/zip",
                    "--cache-control",
                    "public, max-age=31536000, immutable",
                    "--remote",
                    "--config",
                    "wrangler.jsonc",
                ],
                check=True,
                cwd=ROOT / "apps/site",
            )
        else:
            raise SystemExit(f"error: cannot reserve model URL {archive_url}: HTTP {status}")

        if public_sha256(archive_url) != archive_sha:
            raise SystemExit("error: public archive SHA-256 does not match the uploaded archive")

        atomic_write_json(LOCK_PATH, candidate_lock)

    subprocess.run(["xcodegen", "generate"], check=True, cwd=ROOT / "apps/ios")
    print(f"updated lock: {LOCK_PATH}")
    print("Xcode Cloud will consume this release on the next commit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
