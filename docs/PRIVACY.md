# Sift Privacy Notes

Sift is designed as a local-first SMS filtering app. The default path keeps SMS
classification, custom rules, and local personalization on device.

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
  user ever contributed plus their private statistics backups (GDPR Art. 17).
- Access/portability: the same creator-scoped query powers "Export all my submissions"
  (machine-readable JSON, GDPR Art. 15/20).
- Retention: samples remain in the public database while they are useful for
  training; corpora are exported as snapshots via
  `tools/cloudkit/export-training-set.ts`, so deleted samples drop out of all
  future exports.
- Transparency: the public privacy policy is served from the open-source
  repository at
  `https://github.com/backrunner/sift/blob/main/docs/legal/PRIVACY_POLICY.md`.

## Apple review checklist

- Keep the in-app privacy notice visible before remote submission.
- Keep the always-visible in-app legal links available from the main dashboard
  so the privacy policy is easy to reach even before the user chooses remote
  contribution.
- Set the App Store Connect privacy policy URL to
  `https://github.com/backrunner/sift/blob/main/docs/legal/PRIVACY_POLICY.md`.
- Link to
  `https://github.com/backrunner/sift/blob/main/docs/legal/TERMS_OF_SERVICE.md`
  wherever product or store metadata needs Terms of Service.
- Keep `PrivacyInfo.xcprivacy` in the app/framework bundles because the app uses
  `UserDefaults` for preferences, consent, custom rules, model selection, and
  the latest receipt.
- Fill App Store Connect App Privacy details consistently with the shipped app:
  local SMS filtering is on device, and remote sample contribution is optional.
- Do not claim that SMS samples are impossible to identify in all circumstances;
  treat sanitized text conservatively as personal data for operational controls.

## Statistics & purchases

Daily filtering statistics are counters only and are mirrored to the user's
CloudKit **private database** (`FilterStats` records) as a backup we cannot
read. The Premium in-app purchase is processed entirely by Apple via
StoreKit 2; the app stores no payment data. Full store-ready legal documents
live in `docs/legal/PRIVACY_POLICY.md` and `docs/legal/TERMS_OF_SERVICE.md`.

## CloudKit configuration

The container is `iCloud.com.alkinum.sift`; the schema lives in
`infra/cloudkit/schema.ckdb` and is imported with `xcrun cktool import-schema`
(see `infra/cloudkit/README.md`). Public-database permissions allow any
signed-in user to create `SmsSample` records, allow only the creator to modify
or delete their own record, and require authentication to read.

Training exports authenticate with a CloudKit server-to-server key. Keep the
private key PEM outside the repository and pass it via `$CLOUDKIT_PRIVATE_KEY`.

The public legal pages are the Markdown documents in `docs/legal/`; there is no
separate legal-site app to deploy.
