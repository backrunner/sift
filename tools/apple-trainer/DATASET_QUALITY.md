# Dataset Quality Policy

Sift treats training data selection as a model change. More rows are accepted
only when they add a distinct, correctly labelled decision boundary.

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
| SMS Spam Collection | Dataset card says CC BY 4.0; upstream corpus states free use with attribution/no-warranty terms | Yes | Use labelled spam only; skip conversational ham |
| Smishing Dataset IMC25 | CC BY 4.0 | Yes | High-confidence `spam`; retain reported language and source |
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
