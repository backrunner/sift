# Public SMS Sources

## Official template review v90 (2026-11-03; test only)

`Training/signal-official-v90-review.json` records the reuse-terms finding for each official source
checked. Only Kobe and Osaka allow reuse of their SMS wording, so the test set has five template rows:
one new Kobe tax notice plus the four unused v33 candidates. Page text from restricted sites was
deleted. See [the notice](Licenses/official-sms-v90.md). Templates are not received messages.

## Real-source review v90 (2026-11-03; candidate only)

`Training/signal-real-v90-review.json` holds hash-only decisions; bodies stay under ignored
`build/`. Reviewed sources are [Smishing-Dataset-IMC25](https://github.com/reportsmishing/Smishing-Dataset-IMC25)
(CC BY 4.0) and [SmishX](https://github.com/yizhu-joy/SmishX) (MIT, see
[notice](Licenses/smishx-MIT.md)). Assistant review, not independent native review; upstream labels
are not inherited. IMC25 was redacted upstream: rows with placeholder tokens are excluded, and
link-stripped lures form a diagnostic set that training cannot use. Rows with personal names,
phone or account numbers are excluded. The result is 29 training candidates, 45 real-source test rows
and 51 diagnostic rows, split by campaign family. Almost all normal rows are English, so real
Japanese and Chinese business SMS remains an open gap. SmishTank, `SMISH_DT`,
`shaghayegh-hp/Smishing_Dataset` and hrwhisper were not imported because no license for the data
itself could be confirmed.

## Independent junk-head study v29 (2026-10-29)

The [PhishVN content study 1.1.0](https://zenodo.org/records/23634300) supplies
37 reviewed **synthetic non-junk** Vietnamese training examples, after all 209
SMS were inspected. See [attribution and limitations](Licenses/phishvn-content-v1.1.0.md).
All 123 upstream phishing rows are excluded: all use the same placeholder URL,
while all 86 benign rows have no URL. Many phishing bodies are ordinary service
workflows without independent fraud evidence. Importing the binary labels
would teach a particularly dangerous URL/class shortcut. No upstream label is
inherited automatically. Another 35 benign rows have unresolved fine-category
context or are outside the accepted scope;14 exceed the three-per-label cap.

The v29 corpus has 3,535 rows (v28's 3,498 plus 37), with 207 Vietnamese rows and
unchanged complete zh/en/ja coverage. Whole-source connected components and
near families were checked against historical public sources and protected
sets before inference. These additions have no URLs and do not fill the real
business-message-with-links acquisition gap. Their value is measured through
an explicit base-vs-augmented ablation; they are not automatically adopted.

The live CloudKit refresh still has 31 rows, with zero new or changed rows since
v26. Newly discovered Vietnamese mirrors reuse the existing collection;
multilingual UCI mirrors are translations. None supplies a new real
source-independent multilingual final. That release gate remains unmet;
final 84 is spent and final 140 remains disabled and unscored.

## Hard-example review v28 (2026-10-29)

No new public source or synthetic text was added.178 training risk records were
read;3 v26 English records lacked enough context to resolve a fine label and
were removed from the active candidate.59 of the62 v26 additions remain.
The revised corpus has3498 rows and retains the46 v27 source-host repairs.
No evaluation body/gold changed or entered training. This review is assisted
annotation, not independent native-speaker certification. See
[the two-seed method report](../../docs/engineering/signal-hard-example-v28-20261029.md).

## Source-rendering review v27 (2026-10-29)

The four old2528 non-junk-to-junk errors are Vietnamese promotional messages.
Their binary non-junk labels are defensible from the source bodies; the
entertainment teaser has a promotion/subscribed-content fine-label ambiguity.
Upstream labels and brand-like hosts do not authenticate the sender.

Older imports replaced source domains with random shorteners or `example.com`.
Schema4 now requires explicit public-host review, preserves the source host and
scheme, and removes URL path/query identifiers. Typed monetary/shortcode roles
remain synthetic; no original identity is recovered. V27 repairs46 active
training messages using only their own original CSV rows; no evaluation example
is copied into training. The62 v26 public additions are retained.

The paired diagnostic covers50 of54 traceable affected evaluation rows, with4
unreconstructable cases excluded before inference. Historical2528 is untouched;
the diagnostic is exposed and cannot become a fresh final. See
[the review and controlled continuation](../../docs/engineering/signal-false-positive-v27-20261029.md).

## Reviewed new-source experiment v26 (2026-10-29)

The separately pinned [Financial scams detection dataset v2](https://data.mendeley.com/datasets/znsk27yk3h/2)
is available under CC BY 4.0. Attribution, original-file hash and transformation
notes are in [its source notice](Licenses/financial-scams-v2.md). This is a
reviewed experiment, not an automatic import of the publisher's binary labels.
Of 523 source records, 154 English candidates received explicit taxonomy review;
after historical/near-family isolation and family caps, 62 training and 28
development examples were admitted. Nine admitted examples marked `scam`
upstream instead describe ordinary service or promotional content under Sift's
taxonomy. The rest of the source was not admitted.

The publisher describes mixed SMS/chat/email collection. Recipient/channel
provenance is unavailable, many records are template-like, and some rejected
records resemble adapted historical SMS Collection messages. Do not describe
these as 90 independently verified field SMS. Both partitions share this
collection; the 28-row development set is not a source-independent final.
There are no new Japanese public examples or authored translations in v26.
The default approved corpus and retained checkpoint are unchanged until the
experiment satisfies the existing gates. See the v26 engineering report for
training, actual Swift replay and admission evidence.

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

## Reviewed public enrichment (October 27)

`Training/public-sms-reviews-v1.json` pins source files, reuse evidence, message
digests, explicit Sift labels, exclusions and frozen splits. It contains no SMS
bodies. Raw public archives and materialized rows remain under ignored `build/`.
This is an explicit experimental package; it does not silently change the
default raw-source importer or install a classifier.

The selected sources are:

- [NUS SMS Corpus](https://github.com/kite1988/nus-sms-corpus), English and
  Chinese March 2015 release. The authors describe unrestricted public-domain
  release in [their paper](https://arxiv.org/html/1112.2468), sections 4.4 and 6.
  Only message text is read into the corpus. Contributor hashes group the
  split inside the review manifest; profile fields never enter model inputs.
- The existing UCI/CodeSignal source, now with explicitly reviewed personal
  `ham` as abstention and reviewed advertising separated from fraud. The
  legacy Swift importer still skips ham and assigns its spam rows to `spam`;
  do not mistake that binary source label for Sift's taxonomy ground truth.
- [Mishra and Soni, SMS Phishing Dataset, 2022](https://data.mendeley.com/datasets/f45bkkt8pr/1),
  DOI `10.17632/f45bkkt8pr.1`, CC BY 4.0. Use `Dataset_5971.zip` from the
  official file list. Downloading it through the browser worked when the
  direct endpoint returned HTTP 403. Never execute the supplied Python files.
  Labels are coarse and some smishing examples are indistinguishable from
  benign notifications once external sender/URL evidence is removed.
- The existing IMC25 source, expanding its reviewed English/Chinese/Japanese
  coverage. Its reports also contain OTPs, anti-fraud warnings, service
  maintenance notices and surrounding commentary. Review or exclude these;
  do not assign every report to `spam` automatically in the reviewed package.

After acquiring the five manifest-pinned cache files, materialize the package
from the repository root. All repository external suites are always isolated;
repeat `--holdout` to add private originals:

```bash
python3 tools/transformer-trainer/import_reviewed_public.py \
  --manifest tools/apple-trainer/Training/public-sms-reviews-v1.json \
  --cache build/public-source-audit-20261027 \
  --out build/public-enrichment-20261027/train.ndjson \
  --test-out build/public-enrichment-20261027/test.ndjson \
  --report build/public-enrichment-20261027/import-report.json
```

The complete default list comes from `sift_pipeline.holdout_test_sets()`. The
actual October 27 run isolated all 28 established/new CloudKit suites and the four
private originals before adding the public holdout. The importer checks source
hashes, reviewed sanitizer hashes, label IDs, cross-source conflicts,
campaign/contributor splits and duplicate signatures. It redacts identifiers
and rehydrates recognized placeholders with deterministic fictional values.

```bash
pnpm pipeline -- all \
  --reviewed-public-directory build/public-enrichment-20261027
# Optional private suites:
#   --extra-holdout /path/to/private-confirmed.ndjson
```

The package's manifest and train/test hashes are verified on reuse. Curation
removes reviewed identities from the old coarse public input before adding
reviewed training rows, including removals for exclusions and test identities.
Its frozen test is excluded during curation, augmentation and every pre-training
isolation check, even when later stages run separately with the same flag.
Selection/release still requires explicit artifact comparisons, including the
new public suite; the package does not relax any release gate.

The first review inspected 625 candidate bodies: 263 training rows, 160 frozen
test rows, 201 exclusions and one normalized duplicate. Labels were reviewed by
the coding agent, not independently annotated by a human panel. The public test
is dominated by personal conversation and has only one Japanese case; it does
not establish broad Japanese performance. See
[`docs/engineering/public-sms-enrichment-20261027.md`](../../docs/engineering/public-sms-enrichment-20261027.md).

SpamDam remains pending explicit data reuse terms. Sting9 is excluded because
its landing-page CC0 statement conflicts with its specific non-commercial
license. Translated UCI mirrors and LLM-generated extensions are not treated as
independent natural zh/en/ja observations.
# Additional reviewed sources — 2026-10-27 v2

The v2 manifest `Training/public-sms-reviews-v2.json` adds a separate NUS
contributor sample and a small explicitly reviewed portion of the
[Vietnamese SMS dataset](https://github.com/trannguyenthaituan251209/vietnamese_sms_dataset).
The authors publish the dataset under CC BY 4.0 in their README. Attribution:
Tran Nguyen Thai Tuan, Le Hoang Khang, Nguyen Minh Tai, Nguyen Van Thang and
Mai Hoang Dinh, *Vietnamese SMS Dataset with Quality Assurance* (2026).
The source describes real, consented, anonymized messages; this project has
not independently verified those collection claims. We normalize its square
PII placeholders and use deterministic fictional values, with no recovery of
original identifiers.

Hash-pinned files are the official `train.csv` (2,394 rows) and `test.csv`
(597 rows); only **13 training and 18 test examples** are admitted after
content review, duplicate removal and official split checks. Binary source
labels are not Sift labels. Official test families, including unselected
examples, block training. Fresh NUS examples contribute 24 en/25 zh training
and 20 en/26 zh tests with disjoint contributor groups. The final v2 package
has 62 training, 64 test and 41 excluded unique reviewed identities. Reviews
are AI-assisted, not independently human or native-speaker certified.

The v2 importer enables stronger full-message numeric/currency/phone family
checks and vi; v1 remains byte-reproducible. Neither the source's benchmark
scores nor its binary annotations are adopted as evidence for Sift. See the
[review and measured candidate results](../../docs/engineering/signal-corpus-review-20261027.md).

## Further reviewed material and independent confirmation

`Training/public-sms-reviews-v3.json` reviews 911 additional source identities:
651 training, 69 frozen test and 191 exclusions. The 651 admitted training
examples comprise NUS English 328, NUS Chinese 178 and Vietnamese official
training 145. `Training/public-sms-reviews-v4.json` adds 29 real NUS work/personal
messages from 44 unique reviewed identities, excluding 15. These **680 further
real examples** are additions to the earlier v2 corpus before a new grouped
development split; they are not 680 extra optimizer-training rows after that
split. Some become development examples together with their donor groups.

The 196 authored v63 examples and 106 accent-stripped Vietnamese variants are
recorded separately. They are synthetic/derived training material, not new
independent real messages. Derived rows keep a parent text hash and stay on
the same side of the development split as their parent. zh/en/ja authored
triplets also stay together by family.

`Evaluation/public-sms-final-review-v1.json` freezes a hash-selected sample of
100 previously unreviewed official Vietnamese test messages before new model
runs: 66 accepted and 34 excluded. The accepted 66 join the earlier unscored
69 NUS confirmation examples for a 135-row final holdout. The 597 official
Vietnamese test families remain entirely excluded from training, including
unselected and quarantined identities. Content review rejects ambiguous
family-emergency/parcel-payment messages and phishing examples whose only
decisive evidence would disappear under URL redaction. Two source-labeled
spam messages are ordinary bank card transaction alerts under the body-only
taxonomy. No model prediction supplied these decisions.

All additional annotation is AI-assisted coding-agent review, not independent
human/native-speaker certification. This final subset spans en/zh/vi and 15
labels; it does not establish all-class or Japanese field performance. The
previous public v1 160 and v2 64 are development/regression evidence after
repeated candidate comparisons. See the
[generalization protocol and results](../../docs/engineering/signal-generalization-20261027.md).

The additional OTP/OTP-intent/phishing dataset considered during this search
was not admitted: its model-card MIT metadata conflicted with a request to
contact the author for a commercial licence. Duplicated UCI derivatives and
non-commercial or paid corpora were not counted as new reusable observations.

## Recall review v9 (2026-10-28)

The later v11 opt-in package is documented in the
[LLRD continuation study](../../docs/engineering/signal-llrd-continuation-20261028.md):
199 candidates reviewed, 107 content approvals, three further quality/isolation
exclusions, 104 materialized, with 52 train/52 newly grouped development rows.
It uses IMC25, NUS en/zh and Vietnamese official train only, with explicit typed
redactions and hashed source/contributor/campaign lineage. The new annotations
are AI-assisted and do not independently certify natural field authenticity.
The new development set is now inspected; neither continuation replaced A.

`Training/public-sms-recall-reviews-v9.json` records 247 additional reviewed
identities: 112 content approvals, 135 exclusions, and four approvals subsequently
removed as previously reviewed/duplicates. The resulting 108 messages (96 vi,
11 en, one zh; 60 junk) split into 68 training and 40 new grouped development
messages. Vietnamese rows use only the official train partition; IMC25 rows
retain public host evidence with fictional paths and contact/identifier values.
Both source repositories declare CC BY 4.0; source links and review hashes are
in the manifest. Annotation is AI-assisted, not independent native-speaker review.
No new Japanese message survives this increment.

The opt-in `Training/signal-recall-v9.ndjson` includes the approved v8r2 foundation.
Normal business/marketing messages are not forced into upstream junk labels.
Malformed URLs, ambiguous redacted roles and insufficient context are excluded.
The new 40-row cohort is development evidence, **not a final holdout**. All three
trial models failed promotion gates; see the
[recall study](../../docs/engineering/signal-recall-v9-20261028.md).

## Generalization evaluation v15 (2026-10-28)

`Evaluation/public-generalization-v15.json` records a new 80-row public
development cohort and a 140-row reserved final cohort. **None is added to
training.** They retain the prior NUS public-domain / Mendeley2022 CC BY 4.0 /
IMC25 CC BY 4.0 source attribution, supplemented by the authors' [WSPR SMS
phishing release](https://github.com/wspr-ncsu/sms-phishing), commit
`a4f18cedc9909cbf8234eea3c2028080a1e95cd4` ([paper](https://www.kapravelos.com/publications/smsphishing-sp24.pdf)).
The repository declares MIT; its notice is copied in
[`Licenses/wspr-sp24-MIT.txt`](Licenses/wspr-sp24-MIT.txt).

WSPR's current CSV has 68,029 message records and 35,128 campaign summaries;
these are source inventory counts, **not** admitted sample counts. Campaign
summaries contain `#URL`/`#OTP` placeholders and were rejected. Only original
message bodies can supply link evidence; no placeholder is
filled with an invented destination. Source phone-number fields are not used
in sample payloads. The final WSPR body review accepts 21 of 60 candidates,
including two ordinary promotions despite upstream phishing reports.

All annotation precedes model scores and is AI-assisted, not independent
human/native-speaker certification. Existing NUS contributors, exposed hosts,
exact/digit/template families and possible repeated SMS campaign tokens are
excluded. Manual related brand/lure groups use fixed hash representatives.
These controls reduce leakage without certifying all historical campaigns as
independent. Public-origin data may include historical derived content.

Development is en68/zh12 with 16 junk rows; reserved final is en116/zh23/ja1
with 31 junk rows. This is predominantly English evidence and cannot establish
53-leaf trilingual field performance. Both final scoring and promotion remain
blocked by the v16 corrective source audit described below. Hash-only preparation receipts record
support replenishment and stricter campaign exclusions before any inference;
discarded preparation bodies are not retained in review manifests.

## Reviewed training enrichment v16 (2026-10-28)

The v15 `campaignID == messageID` join was invalid; equal numeric IDs do not
establish a representative message. The authors' WSPR release defines separate
raw-message and campaign tables. V16 uses actual campaign URL lists to connect
raw host/template families, and a pinned offline
[Public Suffix List](https://publicsuffix.org/list/) snapshot (MPL-2.0 header
retained in the ignored source cache). Private suffixes and uncommon shortener
TLDs are included. Group IDs are digests; destination numbers are never copied.

The full graph reveals conservative source dependence among old training and
15 v15 development /30 reserved-final rows. The140-row final remains unscored
and unchanged, but is no longer eligible as an independent acceptance test.
See `experiments/signal-public-v15-integrity.json` in the transformer trainer.

`Training/public-sms-v16-reviews.json` records a body/intent decision for every
one of404 unused-group candidates from the same licensed WSPR/NUS/Mendeley/IMC
archives. It accepts173 public rows for training and73 for development,
rejecting158 for ambiguity, privacy residuals, malformed/truncated text or
insufficient original evidence. Upstream binary labels are not Sift gold.
New Japanese public support is only one accepted training SMS; rejected
redacted destinations are never reconstructed to invent phishing evidence.

`Training/signal-enrichment-v16-authored.json` separately attributes180 training
and54 development examples, each from a reserved scenario with zh/en/ja
variants kept in a single partition. These are authored examples, not new field
SMS or a claim of independent native-speaker review. Together with the unchanged
reviewed2,942 rows, `Training/signal-enrichment-v16.ndjson` contains3,295 rows.
The exact additions, hashes and limitations are recorded in
[`signal-enrichment-v16-data-audit.json`](../../docs/engineering/signal-enrichment-v16-data-audit.json).

## New-source screening v32 (2026-10-29; candidate only)

The [JuniorAlive India SMS collection](https://github.com/junioralive/india-spam-sms-classification)
at commit `09137cc677a7d8d24caef0817de41f55a6b3ed44` contains 2,267 CSV rows.
The repository declares MIT; the notice is preserved in
[`Licenses/junioralive-india-MIT.txt`](Licenses/junioralive-india-MIT.txt).
The original CSV SHA256 is
`e6a28126d1c4ec9d805a10cd89f2de2bb63650532102e9f35ab05c909c3a79f3`.

222 keyword-screened English/Latin-script bodies were read; 81 received explicit
body/intent decisions in `Training/public-sms-v32-review.json`. The other 141
remain excluded as uncertain/context-mixed. This is AI-assisted review, not
independent native-speaker verification. Upstream binary spam labels are not
Sift gold: feedback, completed recharge and code delivery can be legitimate,
while an upstream ham record promises stable 10% daily investment returns.

Whole-source host/template/near-duplicate components, including unselected
bridges, were checked against all prior source archives and protected corpora.
Of the 81 decisions, 74 touch previously exposed components, one is a near prior
family, one fails a typed-redaction contract and two exceed 96 tokens. These
are excluded, not relaxed into training. Component roles are hash-assigned
before scoring; `Training/public-sms-v32-exposure.json` retains the hash ledger.

Only **one candidate training row and two reserved development rows** survive.
`Training/signal-native-v32-candidate.ndjson` is the approved 3,497-row base plus
that one candidate. It is **not an approved training corpus** and was not used
by the SAM experiment. `tools/transformer-trainer/Evaluation/signal-native-v32-reserved.ndjson`
remains unscored. These rows share one collection, so they cannot supply a
source-independent final. No native Japanese increment was admitted.
The publisher does not supply per-row donor/channel provenance, and some ham
resembles group chat; this screening does not certify real field authenticity.

## Official template review v33 (2026-10-29; candidate only)

Four **official template derivatives** passed source/body/label review, exact,
digit-normalized, host-component and near-family isolation, retirement checks,
and the 96-token limit: two English NHS templates, one Osaka tax notice and one
Kobe national-health-insurance notice. The two NHS templates contain original
published links; the Japanese originals have no links and none were invented.
All four are fixed to train-candidate role before any inference. The two NHS
examples remain in the same source component. See the
[attribution and transformation notice](Licenses/official-sms-v33.md).

`Training/signal-native-v33-candidate.ndjson` contains the approved 3,497 rows
plus these four candidates (3,501 total). It is not approved for training and
was not used in the v33 optimizer comparison. These are examples published by
the sending organisations, not recipient field observations, an independent
holdout or independent native-speaker certification. No brand whitelist was
created. The previous v32 candidate remains separate; it was not silently merged.

The [Roman Urdu Phishing SMS dataset](https://zenodo.org/records/21810885)
has 1,000 records and declares CC BY 4.0 in the Zenodo API metadata. It was
**not admitted**: numeric normalization leaves 578 unique strings, the first
40 unique representatives show repeated brand/amount templates, and the actual
`Source_Type` column is a semantic category, not per-message field provenance.
This is a screening decision, not a full relabeling of all 1,000 records or proof
that every record is synthetic. No Roman Urdu rows or translations were added.

## Real-source test v95 (2026-11-04; test only)

`Training/signal-real-v95-review.json` holds hash-only decisions for rows with intact hosts from the
existing UCI, Mishra and Soni (CC BY 4.0) and NUS (public domain) archives. The 29 untrained v90
candidates join them. Nothing here enters training. Link-stripped IMC25 reports were not used, since
they cannot test host behaviour. `Cypher-Z/FBS_SMS_Dataset` was not imported: no license is stated.
The set is English and largely dated, so it does not close the real zh/ja business-SMS gap.

## GitHub zh and ja review v96 (2026-11-04; nothing imported)

No GitHub source was usable. `ChangMianRen/Telecom_Fraud_Texts_5` and its copy in
`stlin256/FraudSMS_RAG_Shield` bar commercial use despite a GPL repository license, and the
download was deleted. `SICHUAN3U8633/SMSdata`, `hrwhisper/SpamMessage`, `Cypher-Z/FBS_SMS_Dataset`
and `crpkrs/smishing-Japan` state no license. `Training` for zh and ja therefore uses
`author_cjk_v96.py`: authored rows with brand-style signatures, not received messages.
