# Architecture Overview

## Runtime (iOS)

```text
+- SiftApp (main bundle) -------------------------------------------+
|  SiftAppKit: SiftRootView (dashboard, stats, submit, rules)       |
|    - SettingsView (Premium, restore, submissions, export, erase)  |
|    - PremiumPaywallView (StoreKit 2, PremiumStore)                |
|    - SubmissionHistoryView (CloudKit pagination, item deletion)   |
|  Localizable.xcstrings (zh-Hans source, en/ja translations)       |
+----------------+--------------------------------------------------+
                 | App Group group.com.alkinum.sift
                 |  - ModelSelectionStore
                 |  - SharedRuleStore
                 |  - FilterStatisticsStore
                 |  - SubmissionLedger
+----------------+--------------------------------------------------+
|  MessageFilterExtension (IdentityLookup)                          |
|  Each handle() reloads shared selection and rules                  |
|  -> ClassificationPipeline                                        |
|  -> MessageFilterActionMapper (junk/promotion/transaction/allow)  |
|  -> FilterStatisticsStore.record()                                |
+-------------------------------------------------------------------+
```

### MessageFilterCore

- `ClassificationPipeline` = custom rules first, then classifier, then
  low-confidence fallback.
- Classifier stack by `ModelVariant`:
  - **classic**: `NLModelTextClassifier` (Create ML, `SiftSMSClassifier`) plus
    local personalization (`PersonalizationTrainer`, logistic regression,
    app-side fine-tuning) plus `HeuristicClassifier` fallback for zh/en/ja.
  - **transformer**: Premium IAP unlock using `TransformerTextClassifier`
    with Core ML mmBERT export and a tokenizer sidecar. It is frozen and not
    locally fine-tunable.
- `PrivacySanitizer` has two tracks: context-aware deterministic rules
  (`NSDataDetector` plus regexes for phone, identity documents, email, cards,
  codes, amounts, addresses, and personal names) unioned with the optional
  `CoreMLPIIDetector` token classifier. Model detections use whole-word average
  probabilities and a 0.85 threshold. Because a union can increase false
  positives, model installation is gated by clean-negative evaluation.
- CloudKit:
  - Public database `SmsSample`: anonymous sample, local coarse prediction
    metadata, and `textLanguage`. Creator association supports receipt-based
    deletion, full erasure, and keyset-paginated history by `createdAt`.
  - Private database `FilterStats`: user-private statistics backup using
    per-counter max merge.

## Training Side

```text
fetch-public (synthetic zh/en/ja all labels + 9-language core + public datasets)
   |
fetch-remote (pnpm export:training, CloudKit server-to-server)
   |
curate (rule filters -> placeholder rehydration -> dedupe/conflict removal
        -> language detection -> optional embedding noise filter)
   |
strict-audit (zh/en/ja x 50)
   |
train-classic (Create ML, --language auto)     train-transformer (mmBERT -> Core ML)
   |                                           |
per-label validation report                    checkpoint + finetune + HTML report
   |
--install-ios -> apps/ios/GeneratedModels/ for local model validation
```

Production archives bundle the classic classifier and PII detector. The
Premium Transformer artifacts may exist in `GeneratedModels/` locally, but are
excluded from Xcode target resources and downloaded into the shared App Group
only after entitlement unlock and explicit user selection.

The optional PII pipeline separately trains a 2-layer Distil-mBERT token
classifier with 50% clean negative sentences, then blocks installation unless
PII F1 and both clean false-positive checks pass.

### Accepted Local Baselines (2026-07-11)

- Classic `maxent-boundary-v7`: 98.95% on the fixed 474-row set and 86.67% on
  the breadth-first 150-row promotion boundary set.
- Premium `mmbert-boundary-v8`: 99.58% fixed and 98.00% on the 150-row
  promotion boundary set after one low-LR epoch from the boundary-v7 checkpoint.
  The test set balances broad promotion sectors with order, points, banking,
  carrier-usage, normal-update, and scam negatives.
- PII `pii-boundary-v5`: 99.37% micro F1, 0/498 synthetic clean false
  positives, and 0/45 fixed zh/en/ja hard-negative false positives. CODE
  detections require explicit authentication context at runtime, and PII
  training includes unredacted error-code, product-code, SKU, and build-id
  negatives.

Multilingual strategy: use one multilingual model, not language-specific
models. See `docs/TRAINING.md#3-multilingual-strategy-decision`. The client
writes `textLanguage` with `NLLanguageRecognizer`; training-side detection is a
fallback.

## Data Contracts

- Training rows: `{"text": string, "label": leaf-id}` NDJSON shared by all
  trainers.
- Model sidecars: `<Name>.manifest.json` with labels, sequence length, casing,
  tokenizer or vocabulary file names, and remote artifact metadata. Consumed by
  `TransformerClassifierLoader` and `PIIDetectorLoader`.
- Taxonomy: `packages/taxonomy/taxonomy.json` is the single source of truth.
