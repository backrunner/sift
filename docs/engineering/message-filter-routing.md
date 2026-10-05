# IdentityLookup filtering and routing contract

Audited against Apple's public documentation and the installed iOS 27 SDK on
2026-10-05. This verifies the response contract, not physical SMS delivery or
Apple certification.

Apple's [WWDC22 API walkthrough](https://developer.apple.com/videos/play/wwdc2022/110341/)
requires at most five advertised subcategories **across both** capability
arrays. Runtime replies must use the advertised capabilities. Sift previously
declared nine transactional and three promotional subcategories and could
return all twelve; that violated the configuration contract.

The corrected shared policy declares Finance, Orders, Reminders, Offers and
Coupons. Other transactional labels and old custom destinations such as Health
and Carrier retain `.transaction` with `.none` as the sub-action, placing them
in All Transactions. The generic promotional destination uses `.promotion`
with `.none`, placing it in All Promotions. The in-app mapping menu and its
displayed defaults follow these destinations. The 52-leaf taxonomy and model
predictions are unchanged.

## Unclassified messages and category overrides

Apple defines [ILMessageFilterAction.none](https://developer.apple.com/documentation/identitylookup/ilmessagefilteraction)
as allowing the system to show a message unfiltered when there is insufficient
information. Unclassified messages therefore return `.none` plus `.none`;
they are not sent to a transaction, promotion or junk category.

The final Classic and Signal decision paths normalize abstentions, fallback
placeholders, unknown label IDs, invalid confidence and below-threshold results
to the dedicated abstention label with no taxonomy group. Final decision
thresholds (Classic 0.6, Signal 0.5) are existing Sift policy, not Apple API
requirements. Empty or missing bodies skip both models after checking explicit
user rules, including sender rules for textless MMS. A handler watchdog also
responds with `.none` plus `.none` if no final decision arrives in time.

Previously, a low-confidence fallback used `transaction.other` as a placeholder,
allowing an override for that label to turn an unclassified message into a
filtered one. Overrides now require a valid, classified taxonomy decision.
Recognized `transaction.other` messages remain eligible for user mapping;
unclassified messages do not. Explicit allow/block rules retain priority and
bypass category mappings. The lower-level intermediate placeholder remains
available to the classifier cascade so its heuristic fallback behavior is
unchanged.

| Decision | Final action | Final sub-action |
| --- | --- | --- |
| Unclassified or explicit allow | `.none` | `.none` |
| Explicit block / junk | `.junk` | `.none` |
| Transaction with a supported refinement | `.transaction` | Finance, Orders or Reminders |
| Other transaction | `.transaction` | `.none` (All Transactions) |
| Promotion with a supported refinement | `.promotion` | Offers or Coupons |
| Other promotion | `.promotion` | `.none` (All Promotions) |

No-refinement `.none` under a known transaction/promotion is distinct from an
unclassified top-level `.none` action. A user mapping may change the destination
of a valid classification; the final response still validates its sub-action.

## Extension boundary

The extension also validates the final action/sub-action pair against this
policy immediately before responding, and OSLog diagnostics record the final pair.
Tests cover every taxonomy leaf, both classifier paths with every custom
mapping, stored legacy choices, the five-category limit, menu/capability
alignment and rejection of undeclared or mismatched sub-actions. The final
bridge also rejects a result carrying an abstention decision even if its other
fields incorrectly request filtering. The completion gate permits one response
when inference and the watchdog race.

Apple's [SMS/MMS filtering documentation](https://developer.apple.com/documentation/identitylookup/sms-and-mms-message-filtering)
limits IdentityLookup to unknown-sender SMS/MMS, excludes contacts and iMessage,
and prohibits direct extension network access and shared-container writes.
Sift's production extension reads App Group configuration and prepared model
artifacts; download, compilation/activation and configuration updates run in
the containing app. Extension diagnostics use OSLog only, with no message body
or sender logged and no App Group diagnostic/performance persistence. Shared
JSONL stores are available only to explicitly injected host/test probes.

## Validation and remaining evidence

Validation on 2026-10-05:

- `swift build`, 262 Swift tests and `CoreSmokeTests` passed.
- Three simulator XCTest cases using actual IdentityLookup SDK response objects
  passed, including every taxonomy leaf with every mapping destination.
- The generic iOS app and real extension target built successfully.
- The unchanged Classic model passed its 697-row fixed, promotion, billing/card
  and conversation external suites. Action accuracy was 99.18%, 100%, 100% and
  100% respectively; no benign/transaction message was routed to junk.

Signal routing tests use injected classifiers. These checks are not real Signal
artifact execution in a physical IdentityLookup process, incoming SMS delivery,
or proof that the extension survives its process memory limit.

After installing this fix, reselect Sift under the system SMS filtering
settings to request the corrected capabilities. Existing SMS reclassification
or recovery is not guaranteed by this change.

The reported notification-with-no-visible-message on iOS 27.0.1 with Signal
has not been reproduced on a physical device. This contract violation is a
confirmed defect, but not yet the confirmed cause of that incident. Capture
the affected request's system-log diagnostic stages and any matching Jetsam report
to distinguish routing from the unresolved Signal extension-memory issue
documented in [MESSAGE_FILTER_MEMORY.md](../MESSAGE_FILTER_MEMORY.md).
