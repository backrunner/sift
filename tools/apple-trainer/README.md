# Sift Apple Trainer

Primary Apple base-model adapter for Sift. It reads the shared generic `text`/`label` NDJSON dataset, converts it to Create ML `MLTextClassifier` input at training time, and writes a Core ML `.mlmodel` plus a signed-release-ready manifest.

## Flow

Generate a synthetic seed dataset in generic `text`/`label` NDJSON:

```bash
cd tools/apple-trainer
swift run SiftAppleTrainer --generate-synthetic ../../build/synthetic.ndjson --per-label 50
```

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
  --out ../../build/apple-model \
  --algorithm auto \
  --version corpus-0.1 \
  --install-ios
```

`--algorithm auto` prefers Create ML BERT transfer learning and falls back to MaxEnt if the local environment cannot run BERT. Use `--algorithm maxent` for fast smoke tests.

For production sample export, use the toB worker:

```bash
curl -H "Authorization: Bearer $MASTER_KEY" \
  "https://<tob-worker>/v1/training-set" \
  > build/remote-training.ndjson
```

The worker export is intentionally not an Apple/Core ML format. Keep generated corpora and remote exports as portable `{"text","label"}` NDJSON; any Core ML/Create ML conversion should happen inside this trainer, and future PyTorch trainers can consume the same dataset contract.

Public corpus sources currently used by `--build-public-corpus`:

- `Cypher-Z/FBS_SMS_Dataset`: Chinese fake-base-station spam SMS; preprocessed and anonymized by the dataset authors.
- `codesignal/sms-spam-collection`: English SMS Spam Collection, CC BY 4.0.
- `reportsmishing/Smishing-Dataset-IMC25`: global smishing SMS dataset, CC BY 4.0.

See `PUBLIC_SOURCES.md` for attribution and mapping details.

## Outputs

- `build/apple-model/SiftSMSClassifier.mlmodel`
- `build/apple-model/SiftSMSClassifier.mlmodelc`
- `build/apple-model/SiftSMSClassifier.manifest.json`
- with `--install-ios`: copies `.mlmodel` and manifest into `apps/ios/GeneratedModels`

The Xcode project treats `apps/ios/GeneratedModels` as app and extension resources. Xcode compiles the raw `.mlmodel` into `.mlmodelc` during the app build, while the manifest is read at runtime for the displayed model date/version.

No Apple Developer account is needed for this local Create ML/Core ML workflow. A Developer account and the IdentityLookup entitlement are only needed later for real system SMS filtering outside the in-app sandbox.
