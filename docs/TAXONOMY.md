# Sift SMS Taxonomy And Labeling Guide

The taxonomy has 52 leaf labels across 9 groups. Each group sets the default
system filter action (`systemAction`): `spam -> junk`, `promotion -> promotion`,
and ordinary service messages -> `transaction`. Individual leaves may override
that default when the user-facing intent differs from the group, such as
`carrier.promotion -> promotion`. Leaf granularity is used for model training
and iOS 16+ IdentityLookup sub-action mapping.

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
| `promotion` vs `carrier.promotion` vs `spam` | Canonical intent labels remain: merchant marketing is `promotion`; carrier-owned offers are `carrier.promotion`; fraudulent, phishing, explicit adult, illegal, loan-scam or task-scam content is `spam`. In the user-approved v47 research objective, reviewed non-harmful marketing may route to either promotion or junk. Harmful content must still route to junk. This tolerance does not apply to ordinary service or personal messages. |
| `verification` vs `transaction.account_security` | One-time verification code present -> `verification`. Login alerts, password changes, unusual login notices, or account-security events without a code -> `transaction.account_security`. |
| `transaction.message` vs `transaction.other` | `transaction.message` is content-style platform messaging such as inbox messages, comments, and support replies. `transaction.other` is the status-style fallback. |
| `government.notice` vs `government.reminder` vs `government.policy` | `government.notice` is a personal case or service-progress notice. `government.reminder` is non-personal daily-life guidance from a public authority, such as child safety, fire prevention, public health, fraud awareness, conservation, or community conduct. `government.policy` is a policy, regulation, or formal public-policy announcement. |
| `finance.bank` vs `government.social_security` | Loan applications, loan approvals, and mortgage notices are banking. Social insurance, medical insurance, benefit, certificate, and housing-fund contribution notices are `government.social_security`. |
| `finance.consumption` vs `finance.credit_card` | A purchase, installment purchase/payment, card charge, or card-funded refund follows the underlying money movement: purchase -> `finance.consumption`, refund -> `finance.refund`. `finance.credit_card` is reserved for card-account management such as statement generation, repayment success, minimum payment, due dates, autopay, and credit-limit notices. |
| `carrier.billing` vs `carrier.data_reminder` | `carrier.billing` covers carrier account balances, recharge/payment receipts, due notices, and periodic statements. `carrier.data_reminder` is limited to usage, remaining data/voice, caps, and rollover. |
| `carrier.billing` vs `carrier.service` | A failed activation or renewal whose substantive message is an insufficient monetary balance, required top-up, or balance-based restoration belongs to billing. A request receipt, completed contract/SIM procedure, or technical activation failure without a balance condition belongs to service. Apply this distinction across languages. |
| `carrier.other` vs `carrier.service` vs marketing | A satisfaction survey following carrier support is `carrier.other` and remains a normal service message. Do not infer a sales offer merely from a reply request, link, or survey invitation. |
| Existing entitlement vs new offer | An explicitly completed points/reward credit or existing membership-service event is normal. A new purchase, signup, or upgrade incentive is commercial. Coupon/gift availability without enough context to establish either intent is unresolved; quarantine it instead of guessing from promotional vocabulary. An advertising prefix alone does not resolve an otherwise ambiguous feature notice. |
| Pure greetings vs financial events | A birthday or holiday greeting with no account event, transaction, or offer is `__sift_abstain__`, including when a bank or broker sends it. Sender identity alone does not establish a finance leaf. |

### Evidence required for junk training labels

Review the evidence available in the actual model input, not only the source
dataset's binary label. A customs request, payment deadline, account warning,
verification step, external link, unsubscribe instruction or high advertised
income does not independently establish fraud. Preserve negation and who is
being asked to do what: entering a code in one's own app differs from sending
bank credentials to another person.

Record junk evidence as either a visible malicious-content clause (for example,
credential disclosure, an advance-fee withdrawal trap or explicit adult
solicitation), or a retained destination supported by documented source
evidence. Domain-dependent phishing examples can be valid even when their
surrounding business wording is ordinary. Keep that distinction explicit;
unfamiliar domains alone are not a labeling rule, and historical source
reputation is not a current live security verdict. Do not remove or replace a
decisive host while retaining its phishing gold label.

Exclude unresolved examples from the current training corpus instead of
guessing `spam`, `promotion`, a normal-service leaf or `__sift_abstain__`.
Uncertainty in annotation is not itself an abstention-class training example.
Frozen evaluation labels remain unchanged; disagreement triggers a separately
documented review, never deletion of difficult test cases.

### Research filtering priorities (v47, 2026-11-01)

Preserve the taxonomy IDs and the original fine labels as diagnostic metadata.
Evaluate ordinary messages, commercial invitations and harmful content separately:

- Normal business, verification, account status and personal chat: protect from
  both junk and promotion folders; report each error count separately.
- Reviewed non-harmful marketing: either promotional leaf or `spam` is an accepted
  filtering target. Do not penalize a promotion/junk boundary choice as a normal
  false block. Its canonical subtype accuracy remains a secondary diagnostic.
- Harmful content: only junk counts as successful interception. Fraud routed to
  promotion is still a harmful-content recall failure.
- Missing harm/consent evidence: quarantine from new headline denominators while
  preserving original scores and explicit uncertain counts. Unknown is not ham.
- Narratives describing a scam: keep a separate scenario diagnostic. Do not call
  those descriptions observed attack messages or use their scores as SMS recall.

The v47 training target sidecar makes these distinctions explicit. Commercial
rows use the negative log of summed probability over `spam`, `promotion` and
`carrier.promotion`, without a fine-label distillation term. Normal and harmful
rows retain their strict reviewed targets. A link, unpaid bill, existing coupon
count, authentication step or fraud-awareness warning alone is not marketing
or harm evidence. No runtime taxonomy or user rule is changed by this research
policy. See [the v47 review](engineering/signal-filter-policy-v47-20261101.md).

## iOS Message Filter Mapping

The IdentityLookup extension returns the top-level action plus the closest
iOS 16+ sub-action:

| Sift labels | `ILMessageFilterAction` | `ILMessageFilterSubAction` |
| --- | --- | --- |
| `spam` | `junk` | `none` |
| `promotion`, `carrier.promotion` | `promotion` | `promotionalOffers` |
| future/unknown promotional leaves | `promotion` | `promotionalOthers` |
| `finance.*` | `transaction` | `transactionalFinance` |
| `transaction.order`, delivery and ticket leaves | `transaction` | `transactionalOrders` |
| `transaction.points`, `transaction.member` | `transaction` | `transactionalRewards` |
| work reminders, meetings, training, and transport leaves | `transaction` | `transactionalReminders` |
| `life.medical` | `transaction` | `transactionalHealth` |
| `life.weather` | `transaction` | `transactionalWeather` |
| non-promotional `carrier.*` | `transaction` | `transactionalCarrier` |
| `government.*` | `transaction` | `transactionalPublicServices` |
| all other transactional leaves | `transaction` | `transactionalOthers` |

## Change Process

After editing `packages/taxonomy/taxonomy.json`, run:

```bash
pnpm --filter @sift/taxonomy generate:swift
```

New leaves must add complete zh/en/ja seed templates. `tools/apple-trainer`
checks this during generation. Run
`pnpm pipeline -- curate --strict-audit` to confirm coverage.
