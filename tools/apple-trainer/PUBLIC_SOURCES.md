# Public SMS Sources

`SiftAppleTrainer --build-public-corpus` downloads public datasets at build time and writes a local NDJSON corpus. Raw third-party data is not vendored into this repository.

## Sources

- [Cypher-Z/FBS_SMS_Dataset](https://github.com/Cypher-Z/FBS_SMS_Dataset)
  - Chinese fake-base-station spam SMS.
  - Dataset authors describe it as preprocessed and contact-anonymized.
  - No SPDX license is declared. The repository explicitly requests source-link attribution and citation of the CCS 2020 paper when using the data.
  - Mapping: fraud and illegal-service rows become `spam`; advertising rows become `promotion` or `carrier.promotion`; the `Other` file is content-inferred into safe leaf labels such as `life.weather`, `life.express`, `life.medical`, `work.reminder`, and `carrier.service`. Unmatched personal/ambiguous rows are skipped.

- [codesignal/sms-spam-collection](https://huggingface.co/datasets/codesignal/sms-spam-collection)
  - English SMS Spam Collection.
  - License: CC BY 4.0.
  - Mapping: `spam` rows become `spam`; `ham` rows are skipped because Sift has no generic human-chat label.

- [reportsmishing/Smishing-Dataset-IMC25](https://github.com/reportsmishing/Smishing-Dataset-IMC25)
  - Labeled smishing reports for the IMC 2025 paper.
  - License: CC BY 4.0.
  - Mapping: all retained smishing rows become `spam`.

- [hrwhisper/SpamMessage](https://github.com/hrwhisper/SpamMessage)
  - 800k labelled Chinese SMS (`label\ttext`, label `1`=spam, `0`=ham).
  - Mapping: only spam rows (label `1`) are ingested. They are heuristically split into `spam` (fraud / illegal-services / phishing) and `promotion` (everything else — real merchant marketing). Ham rows are skipped because the dataset's ham is generic Chinese text, not labelled per transactional sub-category, and content-inference on it injects label noise.
  - No data license or original-corpus provenance is declared. It is excluded by the default `curated` source policy and is available only through the explicit `all` opt-in.

## Build Command

```bash
swift run SiftAppleTrainer \
  --build-public-corpus ../../build/public-corpus.ndjson \
  --per-label 140 \
  --public-per-label 250 \
  --public-source-policy curated
```

The generated corpus includes unique synthetic rows for every leaf label plus capped public rows. Public label budgets are filled round-robin across sources, and every output row retains `source`, `sourceLabel`, and `language` metadata for downstream quality reporting.
