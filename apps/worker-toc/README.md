# Sift toC Worker

Public anonymous submission worker.

Production deploy: `https://sift.alkinum.io/api/toc/*`.

Copy `wrangler.template.toml` to ignored `wrangler.toml`, fill in real
Cloudflare IDs, then use Wrangler envs. Prefer root-level checks and deploys:

```bash
pnpm check:workers
pnpm deploy:workers:dry-run
pnpm deploy:worker:toc
```

For local development inside this package, run `pnpm dev`.

`development` uses `workers.dev` and isolated development D1/KV resources.
`production` routes through `sift.alkinum.io` and uses isolated production D1/KV
resources. The worker reads `BASE_PATH=/api/toc` from the production env and
strips it before routing. The privacy and TOS pages live in the Svelte legal
site at the domain root.

Endpoints:

- `GET /health` - public probe
- `GET /v1/taxonomy` - label and group catalog
- `GET /v1/model/manifest` - current bundled model manifest
- `POST /v1/samples` - submit an anonymous, sanitized sample
- `GET /v1/samples/<receiptToken>` - check receipt status
- `DELETE /v1/samples/<receiptToken>` - delete a submitted sample by receipt

The worker rejects identity fields, always stores submissions as remote samples,
and hard-deletes sample rows when a valid receipt token is deleted.
