#if canImport(Testing)
import MessageFilterCore
import Testing

private struct InsuranceEvidenceClassifier: MessageClassifier {
    let labelID: String

    func classify(sender: String?, body: String) -> ClassificationDecision {
        let leaf = SiftTaxonomy.leaf(id: labelID)!
        return ClassificationDecision(
            labelID: leaf.id, labelTitle: leaf.title, groupID: leaf.groupId,
            groupTitle: leaf.groupTitle, confidence: 0.999,
            systemAction: leaf.systemAction, source: .model
        )
    }
}

@Test(arguments: [
    "https://insurance.example/approved-payment",
    "www.insurer.example/renewal-quote-ready",
    "insurance.example/approved-transfer",
    "https://service.example/?insurance=approved&payment=complete",
    "https://保険.example/入金"
])
private func insuranceURLCannotEstablishBusinessContext(url: String) {
    let body = "Payment approved. \(url)"
    #expect(HeuristicClassifier.highPrecisionDecision(for: body)?.labelID != "finance.insurance")
}

@Test(arguments: [
    "住院理赔审核通过，保险金将在周五到账。",
    "The insurer approved your hospital claim and will transfer the benefit on Friday.",
    "入院保険の給付が承認され、金曜に入金されます。",
    "Your claim is still open. Coverage and payment remain subject to the policy assessment.",
    "Your insurer will transfer the approved benefit to your personal account.",
    "保险赔付款已到账，已转至您的个人账户。",
    "保険金をお客様ご本人の口座へ入金しました。",
    "Vertex Insurance: your renewal quote is ready. Confirm before the policy expires."
])
private func clearInsuranceTransactionsRemainProtected(body: String) {
    let primary = InsuranceEvidenceClassifier(labelID: "spam")
    let classifier = CascadingClassifier(primary: primary, fallback: primary)
    for suffix in ["", " https://service.example/status", " https://insurance.example/status"] {
        #expect(classifier.classify(sender: nil, body: body + suffix).labelID == "finance.insurance")
    }
}

@Test(arguments: [
    "保险理赔审核通过，先向理赔员的私人收款码支付解冻款才能领取。",
    "Insurance claim approved. First pay an unlocking charge to the adjuster's personal wallet.",
    "保険金の支払いは承認済みです。担当者個人の口座へ凍結解除料を振り込んでください。",
    "Your insurance renewal quote is ready. Pay an activation fee to continue.",
    "续保报价已出，必须支付解锁费。",
    "保険更新の見積りを確認してください。解除手数料を先に支払ってください。",
    "Insurance payment approved. Please transfer the settlement deposit to the agent's private account.",
    "理赔审核通过，请向客服个人账户转账。",
    "保険金の支払いには担当者個人の口座へ送金してください。",
    "保险理赔审核通过。https://claim.example/a请支付解冻款"
])
private func insuranceRiskLanguageCannotOverrideLearnedSpam(body: String) {
    let primary = InsuranceEvidenceClassifier(labelID: "spam")
    let classifier = CascadingClassifier(primary: primary, fallback: primary)
    #expect(classifier.classify(sender: nil, body: body).labelID == "spam")
}

@Test(arguments: [
    "Your insurer approved the payment. There is no activation fee and no need to transfer anything.",
    "保险理赔审核通过，无需支付解冻费。",
    "保険金は入金済みです。解除手数料は不要です。",
    "Your insurance renewal premium is due. Pay through the policy portal.",
    "保険料のお支払いは契約者用サイトからお願いします。"
])
private func disablingInsuranceOverrideDoesNotCreateAJunkDecision(body: String) {
    let primary = InsuranceEvidenceClassifier(labelID: "finance.insurance")
    let classifier = CascadingClassifier(primary: primary, fallback: primary)
    #expect(classifier.classify(sender: nil, body: body).systemAction == .transaction)
}

@Test
private func insuranceEvidenceRemainsSubordinateToUserRules() {
    let primary = InsuranceEvidenceClassifier(labelID: "spam")
    let pipeline = ClassificationPipeline(classifier: CascadingClassifier(primary: primary, fallback: primary))
    let rule = CustomRule(name: "Known sender", priority: 100,
        sender: SenderMatcher(kind: .exact, pattern: "CUSTOMER"), action: .allow)
    let decision = pipeline.classify(sender: "CUSTOMER",
        body: "Insurance payment approved. Pay an unlocking charge.", rules: [rule])
    #expect(decision.source == .rule)
    #expect(decision.systemAction == .none)
}
#endif
