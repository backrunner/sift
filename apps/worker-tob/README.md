# Sift toB Worker

Internal worker for exports and training data.

Production deploy: `https://sift.alkinum.io/api/tob/*`.

Copy `wrangler.template.toml` to ignored `wrangler.toml`, fill in real
Cloudflare IDs, then set `MASTER_KEY` as a secret:

```bash
pnpm exec wrangler secret put MASTER_KEY --env production
```

For local development, place `MASTER_KEY=...` in ignored `.dev.vars` or
`.dev.vars.development`.

Use Wrangler envs. Prefer root-level checks and deploys:

```bash
pnpm check:workers
pnpm deploy:workers:dry-run
pnpm deploy:worker:tob
```

For local development inside this package, run `pnpm dev`.

`development` uses isolated development D1/KV/R2 resources. `production` routes
through `sift.alkinum.io`, uses isolated production resources, and runs the
retention cron configured in `wrangler.toml`.

Endpoints:

- `GET /health` - public probe
- `GET /v1/stats` - sample counts by label, group, system action, and source
- `GET /v1/export` - full framework-neutral NDJSON export for training and archive pipelines
- `GET /v1/training-set` - portable `text`/`label` NDJSON for any trainer
- `GET /v1/snapshots` - list stored R2 snapshots
- `GET /v1/snapshots/<key>` - download a snapshot by key
- `GET /v1/model/manifest` - read the current manifest from KV
- `PUT /v1/model/manifest` - publish a manifest to KV
- `POST /v1/retention/run` - authenticated manual retention purge

## Training Export

```bash
curl -H "Authorization: Bearer $MASTER_KEY" \
  "https://sift.alkinum.io/api/tob/v1/training-set" \
  > sift-training-set.ndjson
```

Optional filters:

- `source=remote|local`
- `label=<leaf-label-id>`
- `groupId=<group-id>`
- `limit=<1-50000>`

The response is backend-neutral NDJSON with one row per line:

```json
{"text":"您的验证码是 {{CODE}}","label":"verification"}
```

This is the shared dataset contract. The current Apple trainer converts these rows to Create ML input at training time; future PyTorch or other trainers should consume the same format.

## Retention

Production defaults:

- `RETENTION_DAYS=180` for primary D1 sample rows
- `SNAPSHOT_RETENTION_DAYS=30` for R2 snapshots

The scheduled handler and `POST /v1/retention/run` apply the same retention
logic.
