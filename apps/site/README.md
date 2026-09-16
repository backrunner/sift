# Sift website deployment

Production content is served at `https://sift.alkinum.com` by `sift-site`.
Both `.com` and `.io` remain Custom Domains for DNS/TLS. The separate
`alkinum-domain-redirects` Worker, configured in the sibling
`alkinum-official/redirects` directory, intercepts the exact `.io` hostname and
returns HTTP 308 to `.com`, preserving the path and query. Workers.dev and
version preview URLs are disabled.

Build and deploy with `pnpm -C apps/site build` and Wrangler using
`apps/site/wrangler.jsonc`. Keep the `MODEL_BUCKET` R2 binding and the
`/models/*` Worker-first route when deploying. Verify page metadata, robots,
sitemap, localized pages, model manifests, HEAD requests, and byte-range
responses before changing the redirect routes.

Signed model channels/manifests and existing app binaries may contain `.io`
URLs. Do not edit signed payloads in place: redirects preserve those downloads
without changing signatures or artifact hashes. Future signed releases may
adopt `.com` in their normal publishing workflow. Email addresses retain their
existing domains; this website migration does not move mailboxes.

## Website support

The localized `/support`, `/en/support`, and `/ja/support` pages submit to
`POST /api/support` on the canonical `.com` origin. Configure `ONFIRE_API_KEY`
as a Wrangler secret; never expose it as a public variable. Product and type
IDs live in `wrangler.jsonc`. The server validates the returned product and
loads the current immutable OnFire form before each submission. The Sift
product ID is `3faedfa1-43cc-41ef-a001-ea001848ee8e`.

Turnstile uses the shared public site key; its paired secret lives only in
OnFire. OnFire verifies each token once. `SUPPORT_RATE_LIMIT` limits attempts
to five per IP per minute. Exact Origin checks prevent browser CSRF, but are
not cryptographic proof of caller provenance. Never return customer tokens
or expose ticket history based only on the submitted email.

The website has zh-Hans/en/ja copy. OnFire forms have English authored content;
`preferred_language` metadata preserves the website language for support staff,
and the user's original subject and message are preserved. New tickets fall
back to the tenant's default support team. Configure an outbound provider on
the Sift product in OnFire before relying on automated email delivery.

Run `pnpm typecheck`, `pnpm test`, and `pnpm -C apps/site build` from the repo
root. Regenerate binding types from `apps/site` with
`wrangler types worker-configuration.d.ts --env-file wrangler.types.env`.
The env file contains secret names only. UI tests should intercept CAPTCHA
and submission requests; do not create production test tickets or send mail.
