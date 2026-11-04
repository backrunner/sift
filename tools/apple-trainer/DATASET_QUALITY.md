# Dataset Quality Policy

The current reviewed next-data candidate is `Training/signal-hard-example-v28.json`:
3498 rows. The v28 review read178 training-only high-risk messages and removed3
whose credit-limit, medical-insurance or payment/chat context did not resolve
the fine label. The175 other hard cases stay; model disagreement is not a
deletion rule. Both CE/focal arms use this identical corpus in two seeds. The
method experiment did not pass release gates; the retained v21 model stays.

The October29 v27 review found source distortion in Vietnamese public SMS:
random shorteners and `example.com` replaced source hosts, and older rendering
lost monetary/shortcode roles. `Training/signal-false-positive-v27.json`
records that3501-row study, including the62 new public
training rows from v26 and46 own-source URL repairs. All old evaluation gold
and historical corpora remain frozen; exposed evaluation originals and repaired
forms are protected from training. This is a scoped source-rendering review,
not independent native-speaker certification of all3501 messages.

The v13 revision-2 review read all 2,950 predecessor bodies, deleted 161,
repaired 220 bodies, corrected 108 labels and three language hints, then added
153 authored trilingual rows. Counts are mutually exclusive. Six body repairs
also change their labels. Every label still has >=10 examples in zh/en/ja.
The ledger stores hashes of deleted/repaired originals, not quarantined bodies.
Retirement can reject a wrong `(text hash, label)` pair without rejecting the
same text with its adjudicated label. New work-course, restaurant, cold-weather,
discount and Japanese-name slots prevent the confirmed generator role defects.

A new 72-row authored fine-label development set is family-disjoint from training
and remains explicitly synthetic. It is now inspected, not a fresh final. The
v13 trained model fails external non-regression despite its fine72 gain; selected
model A is unchanged. See [the measured review report](../../docs/engineering/signal-reviewed-training-v13-20261028.md).


Sift treats training data selection as a model change. More rows are accepted
only when they add a distinct, correctly labelled decision boundary.

The original v13 approved Signal data candidate was `Training/signal-reviewed-v13.json`
(standalone NDJSON plus hash-bound development). Legacy rejected row bodies
have been deleted; `retired-signal-samples-v8.json` retains SHA256 fingerprints
only. Do not restore discarded pools to increase coverage. Generate clean typed
bodies, without random sender/opt-out/security suffixes or `#number` duplicate
padding; cap each generated template at two rows. Monetary cash examples in
Japanese use whole yen, and broadband billing belongs to `carrier.billing`.
Explicitly reviewed authored coverage is tracked separately from public-origin
data. A strict language-count audit is necessary, but does not certify semantic
labels or independent native review.

## Selection Rules

1. Preserve provenance (`source`, license/reuse terms, language, and original
   label mapping). Unknown-license sources are excluded from the default build.
2. Rehydrate public anonymization tokens with deterministic fake values and
   remove tokenizer artifacts before language detection. No original identity
   value is recovered or retained.
3. Remove exact, digit-normalized, and template-cluster duplicates before
   training. All external holdouts are isolated before candidate comparison.
4. Cap each source/label/language bucket deterministically (500 by default;
   160 is an explicit aggressive-pruning experiment). A large spam corpus
   must not set the representation of unrelated notification labels.
5. Reject unambiguous cross-label conflicts. Downsample high-confidence model
   disagreements from remote samples, then use embedding margins only as a
   noise signal, not as ground truth.
6. Require complete zh/en/ja coverage. Machine translation is not treated as
   natural-language coverage unless a native review has approved the row.
7. Promote a candidate only on leak-free external holdouts. Internal random
   validation is diagnostic and is never the model-selection score.

## Public Source Decisions

| Source | Terms | Default | Decision |
| --- | --- | --- | --- |
| FBS SMS Dataset | Repository requests attribution and CCS 2020 citation; no SPDX identifier | Yes | Manually labelled, anonymized Chinese SMS; keep only conservative mappings |
| SMS Spam Collection | Dataset card says CC BY 4.0; upstream corpus states free use with attribution/no-warranty terms | Yes | Legacy raw import skips ham and uses binary spam labels; the optional hash-pinned review package adds selected ham and corrects marketing/fraud boundaries |
| Smishing Dataset IMC25 | CC BY 4.0 | Yes | Legacy raw import uses report labels; reviewed enrichment corrects clear benign content and excludes context-dependent reports |
| NUS SMS Corpus | Authors describe unrestricted public-domain release; cite Chen and Kan | Reviewed opt-in | Text-only English/Chinese, coding-agent review, known contributors grouped across splits |
| SMS Phishing Dataset 2022 | CC BY 4.0; cite Mishra and Soni | Reviewed opt-in | Review ham/spam/smishing under Sift's taxonomy; remove overlap with existing corpora |
| hrwhisper/SpamMessage | No declared data license or corpus provenance | No | Available only through `--public-source-policy all` |
| Multilingual SMS Spam Collection | GPL-tagged machine translations of the English corpus | No | Duplicate semantics and synthetic language coverage |
| BANKING77 | CC BY 4.0 | No | Banking support questions are not transactional SMS; useful for vocabulary review, not positive training rows |

## Research Basis

- Northcutt et al., *Confident Learning: Estimating Uncertainty in Dataset
  Labels*, JAIR 2021: use predicted disagreement to surface likely label errors.
- Swayamdipta et al., *Dataset Cartography*, EMNLP 2020: preserve informative
  hard examples while separating persistently ambiguous or mislabeled rows.
- Lee et al., *Deduplicating Training Data Makes Language Models Better*, ACL
  2022: duplicate removal reduces memorization and inflated evaluation.
- Sorscher et al., *Beyond Neural Scaling Laws: Beating Power Law Scaling via
  Data Pruning*, NeurIPS 2022: carefully selected subsets can outperform larger
  redundant datasets.

The operational interpretation is conservative: rules and source caps remove
obvious redundancy first; model-based filtering only removes strong outliers;
external boundary sets decide whether a smaller corpus is actually better.

Public report labels are evidence to review, not automatic truth. A malicious
sender or URL can make a message fraudulent without leaving sufficient clues
in the sanitized body. Exclude such ambiguous examples instead of teaching the
model that ordinary pickup, OTP, registration or service-feedback wording is
inherently junk. The October 27 reviewed package records explicit exclusions
and overrides coarse duplicates before curation. Its 160-row public holdout is
separate from training, but its small and uneven language/domain coverage is
not a representative field-accuracy estimate.
# Signal corpus review v2 (2026-10-27)

Use the hash-pinned `Training/signal-corpus-review-v2.json` with
`tools/transformer-trainer/review_signal_corpus.py` for the current reviewed
Signal experiment. It corrects 52 labels, quarantines unreviewed coarse public
sources and ambiguous spam families, and checks external families before and
after sanitization. A payment, renewal, customs, failed delivery, short link,
political opinion or service-rating request alone does not establish spam.
Exclude context-dependent source claims instead of inventing definitive labels.

The v18 boundary re-audit makes this evidence distinction executable for the
current Signal corpus. `Training/signal-boundary-review-v18-evidence.json`
records all 246 previously admitted junk examples: 10 excluded as ambiguous,
153 retained with visible body evidence, and 83 retained with documented
domain-dependent evidence. `approved_signal.verify` and
`run_approved_signal.py` enforce accepted review identities, source hashes,
visible evidence spans and the reviewed 96-token input contract. These checks
protect a completed semantic review against later transformations; they do
not automate or certify the semantic judgment itself.

The audit also found a coverage gap: the 152 zh/en/ja normal banking,
account-security and parcel messages had no URLs, whereas 104 of 246 junk
messages did. Future enrichment must include independently authored or
source-reviewed normal business messages with links, balanced by language and
workflow. Shared vocabulary and URL presence must occur on both sides of a
boundary; avoid making `example.com`, a source name, boilerplate safety advice,
message length or a recognizable template into the label shortcut. If a URL
change removes the only phishing evidence, the transformed body cannot keep
the original hard junk label. See
[`signal-boundary-review-v18-20261028.md`](../../docs/engineering/signal-boundary-review-v18-20261028.md).

The v2 public manifest admits 62 training rows and 64 separately frozen tests;
96 original boundary examples cover complete zh/en/ja families. Original SMS
bodies stay local. Reviews are coding-agent assisted, not independently human
or native-speaker certified. The first public test has known historical
template overlap and is a development regression. See
[`signal-corpus-review-20261027.md`](../../docs/engineering/signal-corpus-review-20261027.md)
for the exact scope, admission/exclusion counts, candidate comparisons and
remaining raw-label release-gate failures.

The subsequent bounded generalization experiment uses 680 additional reviewed
real examples, separately records 196 authored and 106 derived variants, and
splits contributors/families/derived parents before fitting. Its training set
has 18,962 rows; the development set has 234. Historical rows remain training
only, and the initialization checkpoint predates new development-source data.
Early stopping restores the development-selected epoch; two preregistered
learning rates and a correction-weight cap of two limit repeated fitting.
Previously inspected public sets are development regressions. A fresh 135-row
test is frozen before training and evaluated only after model selection;
neither its labels nor inference thresholds may be tuned for a passing score.
See [the protocol and results](../../docs/engineering/signal-generalization-20261027.md).

The October 28 repair moves explicit merchant outflows/incoming credits out
of bank seed arrays, types operational-service slots and protects structured
amounts/URLs from noise. Reviewed public schema 3 requires explicit ambiguous
number/time roles and locale-aware Vietnamese rendering; 12 unrecoverable
source anonymizers remain quarantined. Old derived copies are omitted rather
than counted as independent data. A pinned rebuilt corpus has 9,422 training
and 215 previously inspected grouped-development rows, with core coverage
intact and synthetic source caps. See the
[repair and bounded optimizer/LR comparison](../../docs/engineering/signal-repair-optimizer-20261028.md);
none of its three candidates passes the declared action gates.
