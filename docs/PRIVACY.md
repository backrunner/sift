# Sift Privacy Notes

Sift is designed as a local-first SMS filtering app. The default path keeps SMS
classification, custom rules, and local personalization on device.

## Remote sample contribution

Remote contribution is optional and gated by an in-app consent toggle. When the
user chooses anonymous contribution, the app sends only:

- sanitized SMS text;
- selected label;
- model version;
- schema version.

The public worker rejects identity fields such as sender, account ID, device ID,
phone, email, contact, name, IDFA, and IDFV. Receipt tokens are returned to the
app and only a SHA-256 hash of the receipt is stored in D1.

## GDPR controls

- Lawful basis: remote contribution is consent-based and opt-in.
- Data minimization: only sanitized text and labeling metadata are accepted.
- Erasure: the app stores the most recent receipt token and can delete that row
  from the primary sample database.
- Retention: toB runs a production cron and exposes an authenticated retention
  endpoint. Primary samples default to 180 days; R2 snapshots default to 30 days.
- Transparency: the public privacy policy is served at
  `https://sift.alkinum.io/privacy` by the Svelte legal site.

## Apple review checklist

- Keep the in-app privacy notice visible before remote submission.
- Keep the always-visible in-app legal links available from the main dashboard
  so the privacy policy is easy to reach even before the user chooses remote
  contribution.
- Set the App Store Connect privacy policy URL to
  `https://sift.alkinum.io/privacy`.
- Link to the terms page at `https://sift.alkinum.io/tos` wherever product or
  store metadata needs Terms of Service.
- Keep `PrivacyInfo.xcprivacy` in the app/framework bundles because the app uses
  `UserDefaults` for preferences, consent, custom rules, and the latest receipt.
- Fill App Store Connect App Privacy details consistently with the shipped app:
  local SMS filtering is on device, and remote sample contribution is optional.
- Do not claim that SMS samples are impossible to identify in all circumstances;
  treat sanitized text conservatively as personal data for operational controls.

## Cloudflare configuration

`apps/worker-*/wrangler.template.toml` is safe to commit. Real
`wrangler.toml` files and `.dev.vars*` files are ignored and must stay local or
in CI secrets. Production deploys use Wrangler env `production`.

The legal pages are built from `apps/legal-site` and should be deployed to
Cloudflare Pages at the `sift.alkinum.io` root. The Workers keep only the API
path routes.
