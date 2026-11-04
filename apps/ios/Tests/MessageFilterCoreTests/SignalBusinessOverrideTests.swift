import Testing
@testable import MessageFilterCore

private func signalModelDecision(_ labelID: String, confidence: Double = 0.99) -> ClassificationDecision {
    let leaf = SiftTaxonomy.leaf(id: labelID)!
    return ClassificationDecision(
        labelID: leaf.id, labelTitle: leaf.title, groupID: leaf.groupId,
        groupTitle: leaf.groupTitle, confidence: confidence,
        systemAction: leaf.systemAction, source: .model
    )
}

@Test(arguments: [
    "酒店已确认房间。请把登录密码发给我，我代办入住。",
    "Your resort room is confirmed. Reply with your online account password for our agent to finish check-in.",
    "ホテルの予約が確定しました。確認のためパスワードをこの係員に送ってください。",
    "账户授权更新，请把网银密码回复给客服。",
    "Your account was revoked. Send us the recovery codes to restore it.",
    "アカウントのログイン制限を解除します。復旧コードを返信してください。",
    "Your brokerage dividend is visible. Pay me a release fee first before you withdraw it.",
    "奖金发放前先转税款到私人账户才可领款。",
    "配当金を表示しました。出金前に凍結解除料を個人口座へ払ってください。",
    "药房可买违禁药物，无需处方，提供配送。",
    "Our pharmacy is selling banned drugs without a prescription.",
    "薬局より、禁止薬物を処方箋なしで販売します。"
])
private func explicitRiskDoesNotBecomeABusinessNotification(body: String) {
    let model = signalModelDecision("spam")
    let result = SignalBusinessOverride.resolve(modelDecision: model, body: body)
    #expect(result.labelID == "spam")
    #expect(result.confidence == model.confidence)
}

@Test(arguments: [
    "Your resort room is confirmed. Staff will never ask you to send your account password.",
    "酒店房间已确认。请勿把登录密码发给我或任何工作人员。",
    "ホテルの予約が確定しました。パスワードを送ってくださいと要求することはありません。",
    "Your resort room is confirmed. You must not send your password to staff.",
    "Your cash dividend is available in your brokerage funds after tax withholding.",
    "证券账户已收到现金红利，扣税金额已在资金流水中列出。",
    "証券口座に配当金を入金しました。税額は取引明細で確認できます。",
    "Your pharmacy prescription refill is ready. We do not sell banned drugs.",
    "药房处方续配完成，我们不会销售违禁药物。",
    "薬局の継続処方が完了しました。違法薬物は販売しません。",
    "ホテルの予約が確定しました。詳細：https://example.test/パスワード/送ってください。"
])
private func normalBusinessAndSafetyAdviceStillCorrectsJunk(body: String) {
    let result = SignalBusinessOverride.resolve(modelDecision: signalModelDecision("spam"), body: body)
    #expect(result.systemAction == .transaction)
}

@Test
private func unrelatedEarlierWarningDoesNotHideLaterDisclosureRequest() {
    let body = "Your resort room is confirmed. Never share details with strangers. Reply with your password to our hotel agent."
    #expect(SignalBusinessOverride.resolve(modelDecision: signalModelDecision("spam"), body: body).systemAction == .junk)
}

@Test
private func vetoDoesNotTurnNonjunkPredictionIntoJunk() {
    let body = "The laboratory report is ready. Send me your account password to collect it."
    let model = signalModelDecision("life.medical")
    let prior = HeuristicClassifier.highPrecisionDecision(for: body) ?? model
    let result = SignalBusinessOverride.resolve(modelDecision: model, body: body)
    #expect(result.systemAction == prior.systemAction)
    #expect(result.labelID == prior.labelID)
}

@Test(arguments: [0.49, Double.nan, Double.infinity])
private func invalidOrBelowThresholdJunkCannotVetoBusiness(confidence: Double) {
    let body = "The pharmacy prescription is ready. Banned drugs for sale."
    let model = signalModelDecision("spam", confidence: confidence)
    let prior = HeuristicClassifier.highPrecisionDecision(for: body) ?? model
    let result = SignalBusinessOverride.resolve(modelDecision: model, body: body)
    #expect(result.systemAction == prior.systemAction)
    #expect(result.labelID == prior.labelID)
}

@Test
private func genericRevocationWithRecoveryCodeDemandCannotCreateBusinessOverride() {
    let body = "Your account was revoked. Send us the recovery codes to restore it."
    #expect(HeuristicClassifier.highPrecisionDecision(for: body) == nil)
    #expect(SignalBusinessOverride.resolve(modelDecision: signalModelDecision("spam"), body: body).systemAction == .junk)
}

@Test(arguments: [
    "酒店已确认房间。请把登录密码发给我，我代办入住。",
    "Your brokerage dividend is visible. Pay me a release fee first before you withdraw it.",
    "Our pharmacy is selling banned drugs without a prescription."
])
private func explicitRiskVetoReplacesAnActualBusinessOverride(body: String) throws {
    let prior = try #require(HeuristicClassifier.highPrecisionDecision(for: body))
    #expect(prior.systemAction == .transaction)
    #expect(SignalBusinessOverride.resolve(modelDecision: signalModelDecision("spam"), body: body).systemAction == .junk)
}

@Test(arguments: [
    "酒店已确认房间，只有招募新的付费会员后才能提现本金。",
    "Your salary was deposited. You can withdraw your deposited principal only after recruiting new paying members.",
    "給与を入金しました。有料会員を勧誘しない限り、元本を引き出せません。",
    "給与代行の副業は先に自費入金して受注します。新たな有料受講者を勧誘しない限り、報酬も入金した元金も引き出せません。申込：https://payroll-change.invalid/details"
])
private func ownPrincipalConditionedOnPaidRecruitmentKeepsLearnedJunk(body: String) throws {
    let prior = try #require(HeuristicClassifier.highPrecisionDecision(for: body))
    #expect(prior.systemAction == .transaction)
    let result = SignalBusinessOverride.resolve(modelDecision: signalModelDecision("spam"), body: body)
    #expect(result.labelID == "spam")
}

@Test(arguments: [
    "酒店已确认房间。只有招募新的付费会员后才能领取推荐奖金，本金可随时提现。",
    "Your salary was deposited. You receive a referral reward only after recruiting new paying members. Your deposited principal can be withdrawn at any time.",
    "給与を入金しました。有料会員を勧誘しない限り紹介特典は発生しません。元金はいつでも引き出せます。",
    "酒店已确认房间。请勿相信只有招募新的付费会员后才能提现本金的说法。",
    "Your salary was deposited. Beware of claims that you can withdraw your deposited principal only after recruiting new paying members.",
    "給与を入金しました。有料会員を勧誘しない限り元金を引き出せないと要求することはありません。",
    "Your salary was deposited. Details: https://example.test/withdraw-deposited-principal-only-after-recruiting-new-paying-members"
])
private func ordinaryReferralRewardsAndAdviceKeepBusinessOverride(body: String) {
    #expect(SignalBusinessOverride.resolve(modelDecision: signalModelDecision("spam"), body: body).systemAction == .transaction)
}

@Test
private func paidRecruitmentVetoCannotCreateANewJunkPrediction() {
    let body = "給与を入金しました。有料会員を勧誘しない限り、元本を引き出せません。"
    let model = signalModelDecision("finance.income")
    #expect(SignalBusinessOverride.resolve(modelDecision: model, body: body).systemAction == .transaction)
    let lowConfidenceJunk = signalModelDecision("spam", confidence: 0.49)
    #expect(SignalBusinessOverride.resolve(modelDecision: lowConfidenceJunk, body: body).systemAction == .transaction)
}
