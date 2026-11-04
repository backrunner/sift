import Testing
@testable import MessageFilterCore

private struct IncomeEvidenceClassifier: MessageClassifier {
    let label: String
    let confidence: Double

    func classify(sender: String?, body: String) -> ClassificationDecision {
        let leaf = SiftTaxonomy.leaf(id: label)!
        return ClassificationDecision(labelID: leaf.id, labelTitle: leaf.title,
            groupID: leaf.groupId, groupTitle: leaf.groupTitle, confidence: confidence,
            systemAction: leaf.systemAction, source: .model)
    }
}

private let incomeDemands = [
    "Your recovered wages are frozen. Pay an unfreezing fee to the enforcement assistant's personal account first. It cannot be deducted from the recovery or paid at the court counter. Only then can you collect.",
    "Your backpay is at the settlement centre, but you must pay an identity deposit first. Transfer it to the reviewer's personal bank account. It cannot be taken from the wages; payment is required to release them.",
    "追加給与は精算センターにありますが、本人確認の保証金が先に必要です。審査担当者個人の口座へ振り込んでください。給与との相殺はできず、入金後に支給します。",
    "补发工资已登记，先支付核验保证金。请转到审核员的私人账户，到账后才发放工资。",
    "Your salary is on hold. First pay a release fee to the case worker's private wallet. Your wages will be paid afterwards.",
    "未支給の給与を受け取るには、保証金を事前に支払ってください。係員個人の口座へ送金してください。入金後に支給します。",
    "Your wages are frozen. Never share passwords. Your backpay requires you to pay an identity deposit first. Transfer it to the reviewer's personal bank account. Wages will then be paid."
]

@Test(arguments: incomeDemands)
private func conditionalPrivateWageFeesPreserveLearnedJunk(body: String) {
    #expect(IncomeNoticeEvidence.requiresLearnedDecision(body))
    #expect(HeuristicClassifier.highPrecisionDecision(for: body)?.labelID != "finance.income")
    let model = IncomeEvidenceClassifier(label: "spam", confidence: 0.999)
    #expect(CascadingClassifier(primary: model, fallback: model).classify(sender: nil, body: body).labelID == "spam")
    #expect(SignalBusinessOverride.resolve(modelDecision: model.classify(sender: nil, body: body), body: body).labelID == "spam")
}

@Test(arguments: [
    "Your salary was paid into your personal bank account. Tax and pension contributions were deducted.",
    "工资已到账，个税和社保已代扣。请按账单向物业缴纳停车费。",
    "給与を個人口座へ入金しました。税金と社会保険料は控除済みです。",
    "Your salary was paid. First pay the security deposit to the landlord's private account for your new apartment.",
    "工资已到账。请先向房东的私人账户支付租房保证金。",
    "給与を入金しました。賃貸の保証金は先に管理会社へ支払ってください。",
    "Your wages will be paid after the court's processing fee is settled through the official court portal.",
    "工资发放前的法院费用请通过法院官方缴费平台支付。",
    "給与を入金しました。裁判所手数料は公式窓口で支払ってください。",
    "Your wages were paid. Never pay an identity deposit first to a reviewer's personal bank account.",
    "工资已到账。请勿先向审核员的私人账户支付保证金。",
    "給与を入金しました。担当者個人の口座へ保証金を先に振り込んでくださいと要求することはありません。",
    "Your wages were paid. No deposit is required before transfer to your personal account.",
    "工资已到账，无需先向工作人员个人账户支付解冻费。",
    "給与を入金しました。担当者個人の口座へ先に送金する保証金は不要です。"
])
private func incomeReceiptsFeesAndWarningsKeepNormalOverride(body: String) {
    #expect(!IncomeNoticeEvidence.requiresLearnedDecision(body))
    let model = IncomeEvidenceClassifier(label: "spam", confidence: 0.999)
    let prior = HeuristicClassifier.highPrecisionDecision(for: body)
    #expect(prior?.systemAction == .transaction)
    #expect(CascadingClassifier(primary: model, fallback: model).classify(sender: nil, body: body).systemAction == .transaction)
    #expect(SignalBusinessOverride.resolve(modelDecision: model.classify(sender: nil, body: body), body: body).systemAction == .transaction)
}

@Test(arguments: [
    "Your backpay was paid. No deposit is required before transfer to your personal account.",
    "給与支給前の裁判所手数料は公式窓口で支払ってください。"
])
private func incomeTextWithoutExistingReceiptRuleStaysWithModel(body: String) {
    // These had no income override before this repair; they are not newly
    // recognized receipts. A correct normal model decision must remain normal.
    #expect(!IncomeNoticeEvidence.requiresLearnedDecision(body))
    #expect(HeuristicClassifier.highPrecisionDecision(for: body) == nil)
    let model = IncomeEvidenceClassifier(label: "finance.income", confidence: 0.99)
    #expect(CascadingClassifier(primary: model, fallback: model).classify(sender: nil, body: body).systemAction == .transaction)
    #expect(SignalBusinessOverride.resolve(modelDecision: model.classify(sender: nil, body: body), body: body).systemAction == .transaction)
}

@Test(arguments: [
    "https://payroll.example/salary-pay-identity-deposit-first-to-reviewer-personal-bank-account",
    "payroll.example/工资先向审核员私人账户支付保证金",
    "www.payroll.example/給与保証金先に担当者個人の口座へ振り込んでください"
])
private func incomeRiskInsideURLDoesNotDisableNormalReceipt(url: String) {
    let body = "Your salary was paid. Details: \(url)"
    #expect(!IncomeNoticeEvidence.requiresLearnedDecision(body))
    #expect(HeuristicClassifier.highPrecisionDecision(for: body)?.labelID == "finance.income")
}

@Test(arguments: incomeDemands)
private func incomeEvidenceCannotCreateJunkFromNonjunkModel(body: String) {
    let model = IncomeEvidenceClassifier(label: "finance.income", confidence: 0.99)
    #expect(CascadingClassifier(primary: model, fallback: model).classify(sender: nil, body: body).systemAction == .transaction)
    #expect(SignalBusinessOverride.resolve(modelDecision: model.classify(sender: nil, body: body), body: body).systemAction == .transaction)
}

@Test(arguments: [0.49, Double.nan, Double.infinity])
private func incomeEvidenceDoesNotPromoteInvalidJunkConfidence(confidence: Double) {
    let model = IncomeEvidenceClassifier(label: "spam", confidence: confidence)
    let result = SignalBusinessOverride.resolve(modelDecision: model.classify(sender: nil, body: incomeDemands[0]), body: incomeDemands[0])
    #expect(ModelOutputContract.validatedDecision(result, minimumConfidence: 0.5).systemAction == .none)
}

@Test
private func incomeEvidenceStillHonorsUserAllowRules() {
    let model = IncomeEvidenceClassifier(label: "spam", confidence: 0.999)
    let pipeline = ClassificationPipeline(classifier: CascadingClassifier(primary: model, fallback: model))
    let rule = CustomRule(name: "Known payroll", priority: 100,
        sender: SenderMatcher(kind: .exact, pattern: "PAYROLL"), action: .allow)
    let result = pipeline.classify(sender: "PAYROLL", body: incomeDemands[0], rules: [rule])
    #expect(result.source == .rule)
    #expect(result.systemAction == .none)
}
