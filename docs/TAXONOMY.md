# Sift SMS Taxonomy And Labeling Guide

The taxonomy has 50 leaf labels across 9 groups. Each group determines the
system filter action (`systemAction`): `spam -> junk`, `promotion -> promotion`,
and everything else -> `transaction` (the iOS IdentityLookup API exposes only
those three buckets plus allow). Leaf granularity is for statistics and model
training; it does not change the system-level filtering bucket.

## Design Principles

1. **Never change ids.** Training corpora, released models, and CloudKit data
   use ids as keys. Display titles can be refined at any time.
2. **Keep `*.other` in every group** as a fallback so annotators do not force
   ambiguous messages into the wrong leaf.
3. **Resolve cross-group boundaries by sender intent, not keywords.** See the
   boundary notes below.

## Common Boundary Cases

| Boundary | Decision rule |
| --- | --- |
| `finance.bank` vs `finance.income` vs `finance.consumption` | `finance.bank` is for account and banking-service notices such as balances, cards, branches, and loan application or approval status. `finance.income` is money coming in, such as salary, transfers received, and reimbursements. `finance.consumption` is money going out to a merchant, such as POS purchases, QR payments, or subscription charges. Banking transaction notices should follow fund direction; pure account-management notices stay in `finance.bank`. |
| `life.express` vs `life.logistics` vs `life.pickup_code` | `life.express` is recipient-facing parcel delivery status. `life.logistics` is line-haul, warehouse, freight, dispatch, or cold-chain status. `life.pickup_code` is any arrival notice with a pickup credential; credentialed pickup wins. |
| `promotion` vs `carrier.promotion` vs `spam` | `promotion` is ordinary merchant marketing, including unsubscribe text. `carrier.promotion` is carrier-owned plan, data, broadband, or service marketing. `spam` is illegal, fraudulent, impersonating, phishing, adult, loan-scam, or task-scam content. Annoying but legitimate marketing is promotion; deceptive or unlawful content is spam. |
| `verification` vs `transaction.account_security` | One-time verification code present -> `verification`. Login alerts, password changes, unusual login notices, or account-security events without a code -> `transaction.account_security`. |
| `transaction.message` vs `transaction.other` | `transaction.message` is content-style platform messaging such as inbox messages, comments, and support replies. `transaction.other` is the status-style fallback. |
| `government.notice` vs `government.policy` | `government.notice` is a personal case or service-progress notice. `government.policy` is a public policy announcement. |
| `finance.bank` vs `government.social_security` | Loan applications, loan approvals, and mortgage notices are banking. Social insurance, medical insurance, benefit, certificate, and housing-fund contribution notices are `government.social_security`. |

## Statistics Scope

The app displays statistics by the three `systemAction` buckets (junk,
promotion, normal) and by taxonomy group. Daily count buckets live in the App
Group and are backed up to the user's private CloudKit database as
`FilterStats` records; see `infra/cloudkit/README.md`. Statistics never include
message content, only counts.

## Change Process

After editing `packages/taxonomy/taxonomy.json`, run:

```bash
pnpm --filter @sift/taxonomy generate:swift
```

New leaves must add complete zh/en/ja seed templates. `tools/apple-trainer`
checks this during generation. Run
`pnpm pipeline -- curate --strict-audit` to confirm coverage.
