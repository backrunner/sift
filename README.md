<div align="center">

<img
  src="docs/assets/sift-icon-rounded.png"
  alt="Sift app icon"
  width="128"
/>

<h1>Sift</h1>

<p><strong>Privacy-first SMS filtering for iOS.</strong></p>
<p>
  On-device classification · Consent-gated sample contribution ·
  First-class zh/en/ja taxonomy
</p>

[![Platform](https://img.shields.io/badge/platform-iOS%2018%2B-black?logo=apple)](apps/ios)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](apps/ios/Package.swift)
[![License](https://img.shields.io/badge/code-Apache--2.0-blue)](LICENSE)
[![Brand](https://img.shields.io/badge/name%20%26%20icon-All%20rights%20reserved-8A2BE2)](TRADEMARKS.md)
[![i18n](https://img.shields.io/badge/i18n-zh%20%C2%B7%20en%20%C2%B7%20ja-2ea44f)](docs/TAXONOMY.md)

</div>

---

Sift keeps your SMS inbox from becoming a junk drawer. It classifies messages
into 50 fine-grained categories directly on the iPhone, so filtering does not
send message contents to a server. If users choose to help improve future
models, they can submit a sanitized sample, then review, export, or erase every
remote contribution from inside the app.

> Status: pre-release. The app is not on the App Store yet, and the project does
> not preserve backward compatibility while the product is still taking shape.

## What Makes It Different

| | |
| --- | --- |
| **Local-first filtering** | The IdentityLookup extension classifies messages on device. No network defer path is configured. |
| **50-leaf taxonomy** | One source of truth powers zh/en/ja UI labels, model training, and system buckets. |
| **Dual model path** | A classic Create ML model supports on-device personalization; an optional Premium transformer model is downloaded on demand. |
| **PII-aware samples** | Deterministic redaction rules always run, and an optional Core ML PII detector can widen recall. |
| **Revocable contribution** | CloudKit samples carry no identity fields; users can delete the latest sample, browse history, export JSON, or erase all submissions. |
| **Allow/block rules** | Sender and message-body rules act as user-controlled white and black lists before model classification. |
| **One-command training** | `pnpm pipeline -- all --install-ios` fetches, curates, audits, trains, installs, and reports. |

## Quick Start

```bash
git clone https://github.com/backrunner/sift.git && cd sift
pnpm install

# iOS core: build, tests, and smoke tests
cd apps/ios && swift build && swift test && swift run CoreSmokeTests

# Open the Xcode project (requires XcodeGen)
xcodegen generate && open Sift.xcodeproj

# Train models and install local iOS artifacts
pnpm pipeline -- all --skip fetch-remote --install-ios

# Run the public website locally
pnpm -C apps/site dev
```

Useful day-to-day commands:

```bash
pnpm typecheck
pnpm -C apps/site build
pnpm --filter @sift/taxonomy generate:swift
pnpm export:training
```

## Repository Layout

```text
apps/ios                  SwiftUI app and IdentityLookup extension
apps/site                 SvelteKit/svedocs public website for sift.alkinum.io
packages/taxonomy         50-leaf multilingual taxonomy source of truth
tools/apple-trainer       Create ML trainer and multilingual synthetic corpus
tools/transformer-trainer mmBERT/Core ML trainer and data curation tools
tools/pii-trainer         Optional on-device PII redaction model trainer
tools/cloudkit            CloudKit sample export tools
tools/pipeline            One-command automated training orchestration
infra/cloudkit            CloudKit container schema for cktool import
docs                      Training, taxonomy, privacy, and legal source documents
```

## Reading Map

| Start here | When you need |
| --- | --- |
| [Architecture Overview](agents/architecture.md) | Module boundaries, model flow, CloudKit shape |
| [Development Guide](AGENTS.md) | Hard project rules for agents and maintainers |
| [Training Guide](docs/TRAINING.md) | Dataset curation, Create ML, transformer, and PII training |
| [Taxonomy Guide](docs/TAXONOMY.md) | Label semantics and taxonomy edit workflow |
| [Privacy Notes](docs/PRIVACY.md) | App Store privacy posture and CloudKit details |

## Privacy Commitments

- Filtering always runs on device; the extension process does not use network
  classification.
- Contributions require explicit consent and a redaction preview. Payloads have
  no identity fields.
- Users can exercise GDPR-style rights in app: export all submissions or erase
  all submissions.

Full documents:
[Privacy Policy](docs/legal/PRIVACY_POLICY.md) ·
[Terms of Service](docs/legal/TERMS_OF_SERVICE.md)

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
