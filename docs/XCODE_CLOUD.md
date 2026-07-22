# Xcode Cloud

Sift uses Xcode Cloud to archive with a selected non-beta Xcode toolchain. The
repository does not contain Core ML binaries, so the workflow restores an
immutable built-in model bundle before Xcode resolves or builds the project.
The build fails instead of silently shipping a rules-only or heuristic-only
archive when a required model is missing or changed.

## One-Time Workflow Setup

Create an App Store Connect Xcode Cloud workflow with these settings:

- Project: `apps/ios/Sift.xcodeproj`
- Scheme: `SiftApp`
- Primary action: Archive for iOS
- Xcode version: pin a concrete stable version supported by Xcode Cloud. Do
  not use `Latest` for release archives.
- Start condition: the release branch or a manual build

Keep `apps/ios/Sift.xcodeproj/xcshareddata/xcodecloud/manifest.json` in Git.
Xcode writes the selected product metadata there, and Apple requires teams to
push it to the remote repository.

The normal restore URL and archive SHA-256 are versioned in
`apps/ios/BuiltinModels.lock.json`. No workflow variable is required for the
normal production path. The locked URL points to an immutable object in the
existing `sift-models` Cloudflare R2 bucket, served through the site's
`/models/*` Worker route.

These optional workflow environment variables are reserved for an emergency
override or a private mirror:

| Variable | Secret | Value |
| --- | --- | --- |
| `SIFT_BUILTIN_MODELS_URL` | Usually no | Override for the locked immutable ZIP URL |
| `SIFT_BUILTIN_MODELS_SHA256` | No | Required matching SHA-256 when URL is overridden |
| `SIFT_BUILTIN_MODELS_TOKEN` | Yes | Optional bearer token for a private URL |

Secret variables are not exposed to builds from untrusted pull requests. Use
a public, unguessable immutable URL for PR builds, or limit this archive
workflow to trusted branches.

Apple requires the custom script directory to be next to the selected Xcode
project or workspace. Because Sift's project is `apps/ios/Sift.xcodeproj`, the
scripts live under `apps/ios/ci_scripts/`, not at the repository root. Xcode
Cloud discovers them automatically and performs the following gates:

1. Restore the models after clone, then restore/check them again immediately
   before `xcodebuild` so Core ML code generation can never start without them.
2. Download the ZIP and verify its configured archive SHA-256.
3. Verify every Classic and PII artifact against
   `apps/ios/BuiltinModels.lock.json` and each trainer manifest.
4. Compile both models with the exact Xcode toolchain selected by the workflow.
5. After archiving, require Classic in the app and extension, require PII only
   in the app, and reject any bundled Premium Transformer artifact.

The build log must contain `Restoring built-in models` and `Xcode Cloud model
preflight passed` before the `xcodebuild` phase. Their absence means the
workflow selected a different project path or is building an older commit.

## Branch Policy

All development work is committed and pushed to `main`, which is the local
build branch. Keep `release` reserved for a release candidate that has already
passed local validation:

```bash
git switch main
git pull --ff-only origin main
cd apps/ios && swift build && swift test && swift run CoreSmokeTests
cd ../..
pnpm typecheck && pnpm test
git switch release
git merge --ff-only main
git push origin release
```

The Xcode Cloud workflow is bound only to `release`. Do not commit directly to
`release`, and do not use a failed historical Xcode Cloud commit for a retry;
start a new build from the latest pushed `release` commit.

## Publishing A Built-In Model Bundle

Install only accepted trainer outputs into `apps/ios/GeneratedModels`, then run:

```bash
pnpm publish:ios-models
```

The publisher performs the release transaction in this order:

1. Read the Classic and PII versions from their trainer manifests.
2. Hash all five source artifacts and compile both models with the selected
   Xcode toolchain.
3. Build an immutable ZIP and derive its release URL and SHA-256.
4. Refuse to overwrite a different R2 object; resume safely when an interrupted
   publication already uploaded the exact candidate bytes.
5. Upload to `sift-models`, download it through the public Worker route, and
   verify the full archive SHA-256.
6. Only after public verification succeeds, atomically replace
   `BuiltinModels.lock.json` and regenerate `Sift.xcodeproj`.

Use `pnpm publish:ios-models --dry-run` to run all local gates without
uploading or changing the lock. Use `--models-dir PATH` when validating trainer
output before it is installed under `apps/ios/GeneratedModels`.

After a successful publication, commit and push the updated lock and generated
project. The next Xcode Cloud clone reads that lock and restores the newly
published archive automatically; no workflow environment variable changes are
needed.

Published ZIPs remain under `build/ios-models/` locally and use a dedicated
built-in release key rather than the Premium channel, for example:

```text
models/releases/ios-builtins/maxent-boundary-v9-pii-boundary-v7.zip
```

The publisher runs the corresponding Wrangler upload automatically. For
diagnosis, the equivalent command is:

```bash
cd apps/site
pnpm exec wrangler r2 object put \
  sift-models/models/releases/ios-builtins/maxent-boundary-v9-pii-boundary-v7.zip \
  --file ../../build/ios-models/SiftBuiltinModels-maxent-boundary-v9+pii-boundary-v7.zip \
  --content-type application/zip \
  --cache-control 'public, max-age=31536000, immutable' \
  --remote --config wrangler.jsonc
```

Never replace an object at an existing URL. Every changed Classic or PII model
must also increment its manifest version; the publisher enforces both rules.

For a lower-level local check without packaging or upload, run:

```bash
tools/verify_ios_builtin_models.sh --compile
```

The Premium Sift Signal model is intentionally absent from this bundle and is
still downloaded on demand after entitlement unlock and explicit selection.

Apple references:

- [Writing custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts)
- [Getting started with Xcode Cloud](https://developer.apple.com/documentation/xcode/getting-started-with-xcode-cloud)
