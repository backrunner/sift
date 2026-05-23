# Public SMS Sources

`SiftAppleTrainer --build-public-corpus` downloads public datasets at build time and writes a local NDJSON corpus. Raw third-party data is not vendored into this repository.

## Sources

- [Cypher-Z/FBS_SMS_Dataset](https://github.com/Cypher-Z/FBS_SMS_Dataset)
  - Chinese fake-base-station spam SMS.
  - Dataset authors describe it as preprocessed and contact-anonymized.
  - The repository requests source-link attribution and citation of the CCS 2020 paper.
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

## Build Command

```bash
swift run SiftAppleTrainer \
  --build-public-corpus ../../build/public-corpus.ndjson \
  --per-label 140 \
  --public-per-label 250
```

The generated corpus includes unique synthetic rows for every leaf label plus capped public rows, so high-volume spam datasets do not overwhelm notification categories.
