# Sift Samples Worker

Public anonymous submission worker.

Production deploy: `https://api.sift.alkinum.io/*`.

Copy `wrangler.template.toml` to ignored `wrangler.toml`, fill in real
Cloudflare IDs, then use Wrangler envs. Prefer root-level checks and deploys:

```bash
pnpm check:workers
pnpm deploy:workers:dry-run
pnpm deploy:worker:samples
```

For local development inside this package, run `pnpm dev`.

`development` uses `workers.dev` and isolated development D1/KV resources.
`production` routes through `api.sift.alkinum.io` and uses isolated production
D1/KV resources. The worker owns the API subdomain root, so requests go
directly to `/v1/samples` and related endpoints. The privacy and TOS pages live
in the Svelte legal site at the domain root.

Endpoints:

- `GET /health` - public probe
- `GET /v1/taxonomy` - label and group catalog
- `GET /v1/model/manifest` - current bundled model manifest
- `POST /v1/samples` - submit an anonymous, sanitized sample
- `GET /v1/samples/<receiptToken>` - check receipt status
- `DELETE /v1/samples/<receiptToken>` - delete a submitted sample by receipt

The worker rejects identity fields, always stores submissions as remote samples,
and hard-deletes sample rows when a valid receipt token is deleted.
