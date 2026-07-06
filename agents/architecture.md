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
- `PrivacySanitizer` has two tracks: deterministic rules (`NSDataDetector` plus
  regexes for phone, identity documents, email, cards, codes, amounts,
  addresses, and names) unioned with the optional `CoreMLPIIDetector` token
  classifier. The model can only widen recall; rules remain the baseline.
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
--install-ios -> apps/ios/GeneratedModels/ for classic artifacts only
```

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
