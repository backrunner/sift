# Sift Privacy Notes

Sift is designed as a local-first SMS filtering app. The default path keeps SMS
classification, custom rules, local personalization, and the local cache of
your sanitized submission history on device.

## Remote sample contribution

Remote contribution is optional and gated by an in-app consent toggle. When the
user chooses anonymous contribution, the app writes a single record into the
app's CloudKit **public database** containing only:

- sanitized SMS text;
- selected label and its taxonomy group;
- the app's own predicted label, confidence, and user/model agreement flag
  used to weigh data quality during training;
- model version;
- schema version;
- a coarse language/region tag (for example `zh-CN`) used to balance
  multilingual training corpora;
- a coarse detected text language and source marker (`ios`);
- a client timestamp used for incremental exports.

The payload carries no sender, account ID, device ID, phone, email, contact,
name, IDFA, or IDFV fields. Submission requires an iCloud session on the
device (a CloudKit platform requirement); CloudKit internally associates the
record with its creator, which is exactly what lets the app honor the
"delete my last submission" receipt without storing any identity in the
record itself. Training exports read only the record payload, never creator
identities.

## GDPR controls

- Lawful basis: remote contribution is consent-based and opt-in.
- Data minimization: only sanitized text and labeling metadata are written.
- Erasure: beyond the last-submission receipt, Settings -> Data & Privacy offers
  full erasure — a creator-scoped CloudKit query deletes every sample the
  user ever contributed (GDPR Art. 17).
- Access/portability: the same creator-scoped query powers "Export all my submissions"
  (machine-readable JSON, GDPR Art. 15/20).
- Retention: samples remain in the public database while they are useful for
  training; corpora are exported as snapshots via
  `tools/cloudkit/export-training-set.ts`, so deleted samples drop out of all
  future exports.
- Transparency: the public privacy policy is served at
  `https://sift.alkinum.io/privacy`.

## Local submission-history cache

To make the "My Submissions" screen usable without a CloudKit round-trip on
every visit, Sift keeps the most recently loaded **sanitized** submission
summaries in App Group storage on the device. The cache contains the same
sanitized text, category, and submission time that the screen displays; it
never adds sender, account, device, or other identity fields. It refreshes
periodically and after a manual pull-to-refresh, is updated immediately after
you submit or erase a sample, and is cleared when you erase all submitted data
or delete the app.

## Apple review checklist

- Keep the in-app privacy notice visible before remote submission.
- Keep the always-visible in-app legal links available from the main dashboard
  so the privacy policy is easy to reach even before the user chooses remote
  contribution.
- Set the App Store Connect privacy policy URL to
  `https://sift.alkinum.io/privacy`.
- Link to
  `https://sift.alkinum.io/terms`
  wherever product or store metadata needs Terms of Service.
- Keep `PrivacyInfo.xcprivacy` in the app/framework bundles because the app uses
  `UserDefaults` for preferences, consent, custom rules, model selection, and
  the latest receipt.
- Fill App Store Connect App Privacy details consistently with the shipped app:
  local SMS filtering is on device, and remote sample contribution is optional.
- Do not claim that SMS samples are impossible to identify in all circumstances;
  treat sanitized text conservatively as personal data for operational controls.

## Purchases

The Premium in-app purchase is processed entirely by Apple via StoreKit 2;
the app stores no payment data. Full store-ready legal documents live in
`docs/legal/PRIVACY_POLICY.md` and `docs/legal/TERMS_OF_SERVICE.md`.

## CloudKit configuration

The container is `iCloud.com.alkinum.sift`; the schema lives in
`infra/cloudkit/schema.ckdb` and is imported with `xcrun cktool import-schema`
(see `infra/cloudkit/README.md`). Public-database permissions allow any
signed-in user to create `SmsSample` records, allow only the creator to modify
or delete their own record, and require authentication to read.

Training exports authenticate with a CloudKit server-to-server key. Keep the
private key PEM outside the repository and pass it via `$CLOUDKIT_PRIVATE_KEY`.

The public legal pages are served by the Svelte site under `apps/site` at
`https://sift.alkinum.io/privacy` and `https://sift.alkinum.io/terms`. The
Markdown documents in `docs/legal/` remain the repository source copy.
