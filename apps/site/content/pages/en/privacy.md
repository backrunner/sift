---
title: Sift Privacy Policy
description: How Sift handles SMS, optional sample contributions, and iCloud data.
---

**Effective date: September 8, 2026**

This Privacy Policy describes how Sift ("the App", "we", "us") handles information when you use the Sift iOS application and its optional cloud features, or contact website support. Sift is designed to be **local-first**: SMS filtering, custom rules, and on-device personalization all run on your device by default.

The public copy of this policy is served at `https://sift.alkinum.com/privacy`. If this document and the in-app summary ever differ, this document controls.

## 1. Summary

- SMS messages are classified **on your device**. Message content is never sent to us as part of filtering.
- Contributing training samples is **strictly opt-in**, gated by an explicit consent toggle, sanitized before upload, and reversible. You can delete your most recent submission or **erase everything you ever submitted** inside the App (Settings → Data & Privacy).
- The optional Premium upgrade is a one-time purchase processed entirely by Apple. We never see your payment details.
- The App does not use third-party analytics or advertising SDKs, and we do not sell data. Website support uses OnFire and Cloudflare as described below.

## 2. Information processed on your device only

The following never leaves your device unless you explicitly choose to contribute a sample:

- Incoming SMS content evaluated by the message-filter extension.
- Your custom filtering rules and preferences.
- Locally queued samples used for on-device model personalization.
- A local cache of the sanitized submission summaries shown in *My Submissions*, so the screen can open without querying CloudKit every time.
- Sanitization previews.

The App also keeps rotating local filter diagnostics with processing times, app/model versions, execution stages, memory use, and filtering results. Short-lived random request identifiers and local process numbers help diagnose interrupted filtering; they do not identify your device or account. These logs contain no SMS text, sender information, or phone numbers, are excluded from backup, and are not uploaded automatically or used as training samples. You can explicitly export and share diagnostics for troubleshooting.

## 3. Information you choose to contribute (opt-in)

If, and only if, you enable anonymous contribution and submit a sample, the App writes a single record to the App's CloudKit **public database** containing:

- the sanitized sample text. Phone numbers, ID numbers, vehicle license plates, emails, URLs, bank cards, addresses, codes, and names are replaced with placeholders before upload; a preview shows you exactly what will be sent;
- the category label you selected;
- the App's predicted category and confidence, used to weigh data quality during training;
- the classifier version, a payload schema version, a coarse language or region tag (for example `zh-CN`), and a client timestamp.

The payload contains **no** sender information, phone number, account identifier, device identifier, advertising identifier, or precise location. Submitting requires an iCloud session on your device, which is an Apple platform requirement. Apple's CloudKit internally associates the record with its creator; we use that association solely so **you** can delete your own records, and training exports never read creator identities.

### Website support

When you voluntarily submit the website support form, we process your email,
subject, message, preferred language, and any optional app version, iOS version,
or iPhone model you enter. Requests are stored in our OnFire support service
hosted on Cloudflare and accessed by authorized support staff to handle and
follow up on your request. This service is separate from anonymous CloudKit
training contributions and does not automatically upload SMS or diagnostic logs.
Please do not submit real SMS messages, phone numbers, verification codes,
Apple ID credentials, or payment details.

The form uses Cloudflare Turnstile, which processes browser, device, and network
signals for abuse prevention; the website also uses your IP address to limit
submission attempts. See [Cloudflare's privacy policy](https://www.cloudflare.com/privacypolicy/).
Support processing is based on handling your requested service and our legitimate
interest in responding to requests and preventing abuse, as applicable. Support
records are retained as needed to resolve requests and meet legal obligations.
You can request access or deletion through the support form or
[support@alkinum.io](mailto:support@alkinum.io); we may need to verify your request.
App controls for deleting contributed samples do not delete support tickets.

## 4. Purchases

The Premium upgrade is a non-consumable in-app purchase processed by Apple. We receive no name, address, or payment information. Purchase entitlement is verified on-device through StoreKit. See Apple's privacy policy for how Apple processes purchase data.

## 5. Legal bases (GDPR / UK GDPR)

- **Consent (Art. 6(1)(a))**: anonymous sample contribution. You can withdraw consent at any time by turning the toggle off. Withdrawal does not affect prior processing, and you can additionally erase past contributions (Section 7).
- **Legitimate interest or contract (Art. 6(1)(b), (f))**: operating the local filtering features you install the App to use and validating Premium entitlements.

We treat sanitized sample text conservatively as personal data even though it is designed not to identify you.

## 6. Retention

- Contributed samples are retained while they remain useful for training. Training corpora are rebuilt from the live database, so erased samples drop out of all future model training.
- Local data lives on your device and is removed when you delete the App.

## 7. Your rights

Where GDPR, UK GDPR, CCPA/CPRA, or similar laws apply, you have rights of access, rectification, erasure, restriction, portability, and objection, and the right not to be discriminated against for exercising them. Sift implements the most important ones **directly in the App**:

- **Access and portability**: Settings → Data & Privacy → *Export all my submissions* produces a machine-readable JSON copy of every sample you contributed.
- **Erasure**: Settings → Data & Privacy → *Erase all submitted data* permanently deletes every sample you contributed. *Delete last submission* is also available right after submitting.
- **Withdrawal of consent**: turn off the anonymous-contribution toggle.

For anything else, including complaints, contact **privacy@sift.alkinum.io**. You also have the right to lodge a complaint with your local supervisory authority. We do not sell or share personal information as defined by the CCPA/CPRA.

## 8. International transfers

Contributed samples are stored in Apple's CloudKit infrastructure, which may process data in multiple regions under Apple's data-transfer safeguards. Website support data may be processed in multiple regions through Cloudflare under its applicable data-transfer safeguards.

## 9. Children

Sift is not directed at children under 13, or the equivalent minimum age in your jurisdiction, and we do not knowingly collect personal information from children. The anonymous-contribution feature requires an iCloud account.

## 10. Security

Contributions are sanitized on-device before upload, transported over TLS by CloudKit, and carry no identity fields. Record-level permissions restrict modification and deletion of a sample to its creator. Local files use iOS data protection.

## 11. Changes to this policy

We will update this document when features change and adjust the effective date above. Material changes are additionally surfaced in the App.

## 12. Contact

Alkinum — privacy@sift.alkinum.io
