# Sift

隐私优先的 iOS 短信过滤应用、规则引擎、通用训练数据集、Core ML 训练适配器和匿名收集后端。

## Layout

- `apps/ios` - SwiftUI app, shared core, and extension scaffolding
- `apps/legal-site` - SvelteKit legal pages for `https://sift.alkinum.io/privacy` and `/tos`
- `apps/worker-samples` - anonymous public submission worker at `https://api.sift.alkinum.io/*`
- `apps/worker-datasets` - internal export worker at `https://api.sift.alkinum.dev/*`
- `packages/taxonomy` - canonical category and label catalog
- `packages/contracts` - request/response shapes and validation
- `tools/apple-trainer` - Create ML/Core ML adapter for generic text/label NDJSON datasets and synthetic seed generation

## Notes

- This repo is designed for local-first operation.
- User submission is opt-in only.
- No account, device ID, or user identity is stored in the sample pipeline.
- The public iOS submission endpoint is `https://api.sift.alkinum.io/v1/samples`.
- The public privacy policy URL is `https://sift.alkinum.io/privacy`.
- The public terms URL is `https://sift.alkinum.io/tos`.
- Worker templates are committed as `wrangler.template.toml`; real `wrangler.toml`
  files and `.dev.vars*` stay ignored for open-source safety.

## Local Checks

```bash
pnpm install
pnpm typecheck
pnpm test
pnpm check:workers
pnpm build:legal
cd apps/ios && swift test && swift run CoreSmokeTests
pnpm --filter @sift/worker-samples dev
pnpm --filter @sift/worker-datasets dev
```

Preview the Svelte legal pages:

```bash
pnpm dev:legal
```

## Worker Build And Deploy

Before running Workers locally or deploying, copy each template and fill in the
environment-specific Cloudflare resources. The copied `wrangler.toml` files are
ignored on purpose:

```bash
cp apps/worker-samples/wrangler.template.toml apps/worker-samples/wrangler.toml
cp apps/worker-datasets/wrangler.template.toml apps/worker-datasets/wrangler.toml
```

Keep `development` and `production` resources separate in those files. The
production env routes through `api.sift.alkinum.io` for sample submission and
`api.sift.alkinum.dev` for internal dataset export; development uses
`workers.dev`.
Store the internal dataset worker `MASTER_KEY` as a Wrangler secret, not in
`wrangler.toml`:

```bash
cd apps/worker-datasets
pnpm exec wrangler secret put MASTER_KEY --env development
pnpm exec wrangler secret put MASTER_KEY --env production
```

Local development runs each Worker with the `development` env:

```bash
pnpm --filter @sift/worker-samples dev   # http://127.0.0.1:8787
pnpm --filter @sift/worker-datasets dev   # http://127.0.0.1:8788
```

The normal preflight is:

```bash
pnpm check:workers
```

Production deploys are pinned to Wrangler env `production`. The deploy script
validates real `wrangler.toml` files, refuses template placeholders and inline
`MASTER_KEY`, runs Worker build/test, checks Wrangler auth, and then deploys:

```bash
pnpm deploy:workers:dry-run
pnpm deploy:workers
```

Single Worker releases are available when needed:

```bash
pnpm deploy:worker:samples
pnpm deploy:worker:datasets
```

Deploy `apps/legal-site/build` to Cloudflare Pages on `sift.alkinum.io`; keep
the Worker routes on `api.sift.alkinum.io/*` and `api.sift.alkinum.dev/*`.

Build a local corpus from synthetic seed rows plus public SMS datasets as generic `text`/`label` NDJSON, then train with Apple's native stack. The corpus stays framework-neutral; `SiftAppleTrainer` converts rows into Create ML training data only when it trains:

```bash
cd tools/apple-trainer
swift run SiftAppleTrainer --build-public-corpus ../../build/public-corpus.ndjson --per-label 80 --public-per-label 500
swift run SiftAppleTrainer --input ../../build/public-corpus.ndjson --out ../../build/apple-model --algorithm auto --install-ios
```

The internal dataset worker exports the same generic production training rows directly:

```bash
curl -H "Authorization: Bearer $MASTER_KEY" \
  "https://api.sift.alkinum.dev/v1/training-set" \
  > build/remote-training.ndjson

cd tools/apple-trainer
swift run SiftAppleTrainer --input ../../build/remote-training.ndjson --out ../../build/apple-model --algorithm auto --install-ios
```

`apps/ios/GeneratedModels` currently contains a local Create ML BERT seed model and manifest for Xcode debug builds. A paid Apple Developer account is not required for local Create ML training or the in-app sandbox; it is required later for real IdentityLookup message-filter entitlement provisioning.

Privacy and App Store review notes live in `docs/PRIVACY.md`.
