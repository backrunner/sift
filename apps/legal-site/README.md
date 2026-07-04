# Sift Legal Site

SvelteKit static site for the public legal pages:

- `https://sift.alkinum.io/privacy`
- `https://sift.alkinum.io/tos`

The visual system mirrors the iOS app: local-first copy, system typography,
Sift mint/halo accents, and quiet rounded surfaces.

## Local Development

```bash
pnpm --filter @sift/legal-site dev
pnpm --filter @sift/legal-site check
pnpm --filter @sift/legal-site build
```

The production build writes static files to `apps/legal-site/build`.

## Deployment

Deploy `build/` to Cloudflare Pages with the custom domain
`sift.alkinum.io`. Data collection now goes directly through CloudKit from the
iOS app, so the static legal pages are the only deployable surface in this
package.
