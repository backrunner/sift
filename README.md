<div align="center">

# Sift

**Privacy-first on-device SMS filtering for iOS**

On-device classification · Anonymous and revocable sample contribution ·
First-class zh/en/ja support

[![Platform](https://img.shields.io/badge/platform-iOS%2018%2B-black?logo=apple)](apps/ios)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](apps/ios/Package.swift)
[![License](https://img.shields.io/badge/code-Apache--2.0-blue)](LICENSE)
[![Brand](https://img.shields.io/badge/name%20%26%20icon-All%20rights%20reserved-8A2BE2)](TRADEMARKS.md)
[![i18n](https://img.shields.io/badge/i18n-zh%20%C2%B7%20en%20%C2%B7%20ja-2ea44f)](docs/TAXONOMY.md)

</div>

---

Your SMS inbox should not be a junk drawer. Sift classifies messages into
50 fine-grained categories on your iPhone, so message contents never need to
leave the device. When users choose to help improve the model, they can submit
an anonymized, sanitized sample and later review, export, or erase everything
they contributed.

## Highlights

| | |
| --- | --- |
| **Dual-model architecture** | A classic Create ML model with on-device personalization plus an on-demand Premium mmBERT transformer model. |
| **First-class trilingual support** | The taxonomy and app UI fully support zh/en/ja; training data also covers es, pt, fr, de, ru, ko, id, vi, and th for core categories. |
| **Two-track redaction** | Deterministic rules plus an optional on-device Core ML PII detector. The union is used, so rules remain the floor. |
| **Anonymous, revocable contribution** | CloudKit public database samples contain no identity fields; receipt-based deletion, history deletion, GDPR erasure, and JSON export are supported. |
| **Local statistics** | Daily filtering counts contain no message content and are backed up to the user's private iCloud database. |
| **Automated training pipeline** | `pnpm pipeline -- all --install-ios` fetches data, curates it, audits language coverage, trains models, and emits HTML reports. |
| **Isolated tests** | Swift, TypeScript, and Python tests avoid external services and isolate shared state. |

## Quick Start

```bash
git clone <repo> && cd sift
pnpm install

# iOS core: build, tests, and smoke tests
cd apps/ios && swift test && swift run CoreSmokeTests

# Open the Xcode project (requires XcodeGen)
xcodegen generate && open Sift.xcodeproj

# Train models and install local iOS artifacts
pnpm pipeline -- all --skip fetch-remote --install-ios
```

## Repository Layout

```text
apps/ios                  SwiftUI app and IdentityLookup extension
apps/legal-site           Static privacy policy and terms site
packages/taxonomy         50-leaf multilingual taxonomy source of truth
tools/apple-trainer       Create ML trainer and multilingual synthetic corpus
tools/transformer-trainer mmBERT/Core ML trainer and data curation tools
tools/pii-trainer         Optional on-device PII redaction model trainer
tools/cloudkit            CloudKit sample export tools
tools/pipeline            One-command automated training orchestration
infra/cloudkit            CloudKit container schema for cktool import
docs                      Training, taxonomy, privacy, and legal documents
```

Further reading:
[Training Guide](docs/TRAINING.md) ·
[Architecture Overview](agents/architecture.md) ·
[Development Guide](AGENTS.md) ·
[Taxonomy Guide](docs/TAXONOMY.md) ·
[Privacy Notes](docs/PRIVACY.md)

## Privacy Commitments

- Filtering always runs on device; the extension process does not use the
  network.
- Contributions require explicit consent and a redaction preview. Payloads have
  no identity fields.
- Statistics are numeric counts only and live in the user's private iCloud
  database.
- Users can exercise GDPR-style rights in app: export all submissions or erase
  all submissions.

Full documents:
[Privacy Policy](docs/legal/PRIVACY_POLICY.md) ·
[Terms of Service](docs/legal/TERMS_OF_SERVICE.md)
(public copies at `sift.alkinum.io/privacy` and `/tos`).

## License And Trademarks

The code is licensed under [Apache License 2.0](LICENSE).
The "Sift" name, app icon, and brand assets are not part of the open-source
license and remain all rights reserved. Forked distributions must use a
different name, icon, bundle id, and CloudKit container; see
[TRADEMARKS.md](TRADEMARKS.md).

---

<div align="center">
<sub>Built for a quieter inbox · © Alkinum</sub>
</div>
