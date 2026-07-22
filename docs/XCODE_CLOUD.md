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

The scripts under `ci_scripts/` run automatically. They perform the following
gates:

1. Download the ZIP and verify its configured archive SHA-256.
2. Verify every Classic and PII artifact against
   `apps/ios/BuiltinModels.lock.json` and each trainer manifest.
3. Compile both models with the exact Xcode toolchain selected by the workflow.
4. After archiving, require Classic in the app and extension, require PII only
   in the app, and reject any bundled Premium Transformer artifact.

## Publishing A Built-In Model Bundle

Install only accepted trainer outputs into `apps/ios/GeneratedModels`, update
`apps/ios/BuiltinModels.lock.json`, and regenerate the project:

```bash
cd apps/ios
xcodegen generate
cd ../..
tools/package_ios_builtin_models.sh
```

Upload the resulting ZIP from `build/ios-models/` to immutable object storage.
The existing `https://sift.alkinum.io/models/...` R2-backed route is suitable,
but use a dedicated built-in release key rather than the Premium channel, for
example:

```text
models/releases/ios-builtins/maxent-boundary-v9-pii-boundary-v7.zip
```

With the production Cloudflare account selected, the corresponding upload is:

```bash
pnpm -C apps/site exec wrangler r2 object put \
  sift-models/models/releases/ios-builtins/maxent-boundary-v9-pii-boundary-v7.zip \
  --file ../../build/ios-models/SiftBuiltinModels-maxent-boundary-v9+pii-boundary-v7.zip \
  --content-type application/zip \
  --cache-control 'public, max-age=31536000, immutable' \
  --remote --config wrangler.jsonc
```

Set `archive.url` in `BuiltinModels.lock.json` to that object URL and set
`archive.sha256` to the value printed by the packaging tool. Never replace an
object at an existing URL. Publish a new key and update the lock for each
accepted model release.

Before switching the workflow variables, test the same artifact locally:

```bash
tools/verify_ios_builtin_models.sh --compile
```

The Premium Sift Signal model is intentionally absent from this bundle and is
still downloaded on demand after entitlement unlock and explicit selection.
