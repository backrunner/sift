# PhishVN content study 1.1.0

Source: [PhishVN content study: page-content fusion and paraphrase-evasion data](https://zenodo.org/records/23634300),
Thai Nguyen Vu, published 2026-10-25, version 1.1.0.

The source metadata declares [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
The cached Zenodo record and README are pinned in the v29 corpus manifest.
`synthetic_sms.csv` SHA-256:
`239e2170d865cd851348a8808ec1a34b64e0dd05f44ce68a625720ab78b8cd78`.

Sift reviewed all 209 SMS rows and retained 37 non-junk examples for a bounded
synthetic training ablation. Changes: whitespace normalization, independent
Sift taxonomy annotation, exclusion of ambiguous rows and a three-row cap per
label. No source URL was replaced or added to admitted examples.

The publisher explicitly describes both classes as model-generated. This
corrected description takes precedence over stale `source=author`,
`is_llm=0`, and `label_source=human` CSV fields. These are not real user SMS or
an independent real-world holdout. All 123 upstream phishing rows use the same
placeholder destination; their labels are not admitted because fraud cannot
be established from the visible body plus that placeholder. No native-speaker
or donor-provenance certification is claimed.
