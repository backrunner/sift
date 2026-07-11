# Sift Apple Trainer

Primary Apple base-model adapter for Sift. It reads the shared generic `text`/`label` NDJSON dataset, converts it to Create ML `MLTextClassifier` input at training time, and writes a Core ML `.mlmodel` plus a signed-release-ready manifest.

## Flow

Generate a multilingual synthetic seed dataset in generic `text`/`label`
NDJSON. The default emphasizes zh, covers every label in en, and adds core
categories for es/pt/fr/de/ru/ja/ko/id/vi/th:

```bash
cd tools/apple-trainer
swift run SiftAppleTrainer --generate-synthetic ../../build/synthetic.ndjson \
  --per-label 50 --intl-per-label 12 --languages all
```

- `--per-label` controls Chinese rows per label; `--intl-per-label` controls
  rows per covered label for every other language (0 disables them).
- `--languages zh` reproduces a Chinese-only corpus; any comma-separated
  subset of `zh,en,es,pt,fr,de,ru,ja,ko,id,vi,th` works.

Build a richer generic local corpus from synthetic rows plus public SMS datasets:

```bash
swift run SiftAppleTrainer \
  --build-public-corpus ../../build/public-corpus.ndjson \
  --per-label 140 \
  --public-per-label 250
```

Train from the generic corpus with Apple's native stack and install the raw model into the iOS project resources:

```bash
swift run SiftAppleTrainer \
  --input ../../build/public-corpus.ndjson \
  --test-input Evaluation/promotion-regressions.ndjson \
  --out ../../build/apple-model \
  --algorithm maxent \
  --version corpus-0.1 \
  --install-ios
```

`Evaluation/promotion-regressions.ndjson` is a fixed zh/en/ja holdout for
merchant promotions, game offers, rewards malls, carrier points, and factual
points notifications. It is never merged into training rows; both pipeline
trainers evaluate it after validation to catch regressions at these boundaries.

`--algorithm maxent` is the validated default for the current 50-label SMS
corpus: it trains in seconds, produces a tiny model, and outperforms Create ML
BERT transfer learning on the local validation splits. Use `--algorithm bert`
or `--algorithm auto` only for comparison runs. Use `--split-seed` to repeat
validation on alternate deterministic per-label holdout splits.

Training language: `--language auto` (default) inspects the corpus — a ≥90%
single-language corpus trains with that language hint, anything mixed trains
language-agnostic. Force with `--language zh-Hans` / `--language en` /
`--language multilingual`.

For production sample export, pull live CloudKit submissions with the
repo-root script (`pnpm export:training`, see `tools/cloudkit/README.md`);
it writes the same portable `{"text","label"}` NDJSON. Any Core ML/Create ML
conversion should happen inside this trainer, and the transformer trainer
(`tools/transformer-trainer`) consumes the same dataset contract.

Public corpus sources currently used by `--build-public-corpus`:

- `Cypher-Z/FBS_SMS_Dataset`: Chinese fake-base-station spam SMS; preprocessed and anonymized by the dataset authors.
- `codesignal/sms-spam-collection`: English SMS Spam Collection, CC BY 4.0.
- `reportsmishing/Smishing-Dataset-IMC25`: global smishing SMS dataset, CC BY 4.0.
- `hrwhisper/SpamMessage`: ~800k labelled Chinese SMS; spam rows are split into
  Sift's `spam` vs `promotion` buckets heuristically.

See `PUBLIC_SOURCES.md` for attribution and mapping details.

## Outputs

- `build/apple-model/SiftSMSClassifier.mlmodel`
- `build/apple-model/SiftSMSClassifier.mlmodelc`
- `build/apple-model/SiftSMSClassifier.manifest.json`
- with `--install-ios`: copies `.mlmodel` and manifest into `apps/ios/GeneratedModels`

The Xcode project treats `apps/ios/GeneratedModels` as app and extension resources. Xcode compiles the raw `.mlmodel` into `.mlmodelc` during the app build, while the manifest is read at runtime for the displayed model date/version.

No Apple Developer account is needed for this local Create ML/Core ML workflow. A Developer account and the IdentityLookup entitlement are only needed later for real system SMS filtering outside the in-app sandbox.
