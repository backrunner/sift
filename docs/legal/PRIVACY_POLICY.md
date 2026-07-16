# Sift Privacy Policy

**Effective date: July 17, 2026**

This Privacy Policy describes how Sift ("the App", "we", "us") handles
information when you use the Sift iOS application and its optional cloud
features. Sift is designed to be **local-first**: SMS filtering, custom rules,
and on-device personalization all run on your device by default.

The public copy of this policy is served at
`https://sift.alkinum.io/privacy`. If this document and the in-app summary ever
differ, this document controls.

## 1. Summary

- SMS messages are classified **on your device**. Message content is never
  sent to us as part of filtering.
- Contributing training samples is **strictly opt-in**, gated by an explicit
  consent toggle, sanitized before upload, and reversible: you can delete
  your most recent submission or **erase everything you ever submitted** from
  inside the App (Settings → Data & Privacy).
- The optional Premium upgrade is a one-time purchase processed entirely by
  Apple. We never see your payment details.
- We do not run our own servers, do not use third-party analytics or
  advertising SDKs, and do not sell data.

## 2. Information processed on your device only

The following never leaves your device unless you explicitly choose to
contribute a sample:

- Incoming SMS content evaluated by the message-filter extension.
- Your custom filtering rules and preferences.
- Locally queued samples used for on-device model personalization.
- A local cache of the sanitized submission summaries shown in *My
  Submissions*, so the screen can open without querying CloudKit every time.
- Sanitization previews.

## 3. Information you choose to contribute (opt-in)

If — and only if — you enable anonymous contribution and submit a sample, the
App writes a single record to the App's CloudKit **public database**
containing:

- the sanitized sample text (phone numbers, ID numbers, vehicle license plates,
  emails, URLs, bank cards, addresses, codes, and names are replaced with
  placeholders before upload; a preview shows you exactly what will be sent);
- the category label you selected;
- the App's own predicted category and confidence (used to weigh data
  quality during training);
- the classifier version, a payload schema version, a coarse language/region
  tag (for example `zh-CN`), and a client timestamp.

The payload contains **no** sender information, phone number, account
identifier, device identifier, advertising identifier, or precise location.
Submitting requires an iCloud session on your device (an Apple platform
requirement). Apple's CloudKit internally associates the record with its
creator; we use that association solely so **you** can delete your own
records, and training exports never read creator identities.

## 4. Purchases

The Premium upgrade is a non-consumable in-app purchase processed
by Apple. We receive no name, address, or payment information. Purchase
entitlement is verified on-device through StoreKit. See Apple's privacy
policy for how Apple processes purchase data.

## 5. Legal bases (GDPR / UK GDPR)

- **Consent (Art. 6(1)(a))** — anonymous sample contribution. You can
  withdraw consent at any time by turning the toggle off; withdrawal does not
  affect prior processing, and you can additionally erase past contributions
  (Section 7).
- **Legitimate interest / contract (Art. 6(1)(b), (f))** — operating the
  local filtering features you install the App to use, and validating
  Premium entitlements.

We treat sanitized sample text conservatively as personal data even though it
is designed not to identify you.

## 6. Retention

- Contributed samples are retained while they remain useful for training.
  Training corpora are rebuilt from the live database, so erased samples drop
  out of all future model training.
- Local data lives on your device and is removed when you delete the App.

## 7. Your rights

Where GDPR, UK GDPR, CCPA/CPRA, or similar laws apply, you have rights of
access, rectification, erasure, restriction, portability, and objection, and
the right not to be discriminated against for exercising them. Sift
implements the most important ones **directly in the App**:

- **Access / portability**: Settings → Data & Privacy → *Export all my
  submissions* produces a machine-readable JSON copy of every sample you
  contributed.
- **Erasure**: Settings → Data & Privacy → *Erase all submitted data*
  permanently deletes every sample you contributed. *Delete last submission*
  is also available right after submitting.
- **Withdrawal of consent**: turn off the anonymous-contribution toggle.

For anything else (including complaints), contact
**privacy@sift.alkinum.io**. You also have the right to lodge a complaint
with your local supervisory authority. We do not sell or share personal
information as defined by the CCPA/CPRA.

## 8. International transfers

Contributed samples are stored in Apple's CloudKit infrastructure, which may
process data in multiple regions under Apple's data-transfer safeguards. We do
not operate independent servers.

## 9. Children

Sift is not directed at children under 13 (or the equivalent minimum age in
your jurisdiction), and we do not knowingly collect personal information from
children. The anonymous-contribution feature requires an iCloud account.

## 10. Security

Contributions are sanitized on-device before upload, transported over TLS by
CloudKit, and carry no identity fields. Record-level permissions restrict
modification and deletion of a sample to its creator. Local files use iOS
data protection.

## 11. Changes to this policy

We will update this document when features change and adjust the effective
date above. Material changes are additionally surfaced in the App.

## 12. Contact

Alkinum — privacy@sift.alkinum.io
