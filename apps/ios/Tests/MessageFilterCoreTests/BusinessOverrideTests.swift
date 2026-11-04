#if canImport(Testing)
import Foundation
@testable import MessageFilterCore
import Testing

private struct BusinessOverrideClassifier: MessageClassifier {
    let labelID: String

    func classify(sender: String?, body: String) -> ClassificationDecision {
        let leaf = SiftTaxonomy.leaf(id: labelID)!
        return ClassificationDecision(
            labelID: leaf.id, labelTitle: leaf.title, groupID: leaf.groupId,
            groupTitle: leaf.groupTitle, confidence: 0.99,
            systemAction: leaf.systemAction, source: .model
        )
    }
}

private struct BusinessOverrideLoader: TransformerRuntimeLoading {
    let classifier: BusinessOverrideClassifier

    @concurrent
    func loadTransformer(identity: ModelArtifactIdentity) async -> TransformerRuntimeLoadResult {
        TransformerRuntimeLoadResult(classifier: classifier)
    }
}

private func businessOverrideResult(_ text: String, labelID: String = "spam") async -> MessageFilterResult {
    let classifier = BusinessOverrideClassifier(labelID: labelID)
    let engine = MessageFilterEngine(
        classicClassifier: classifier,
        transformerLoader: BusinessOverrideLoader(classifier: classifier),
        transformerDeviceSupport: .supported
    )
    let identity = ModelArtifactIdentity(variant: .transformer, modelABI: "test", releaseSequence: 1, sha256: "fixture")
    let result = await engine.classify(
        MessageFilterRequest(sender: nil, body: text),
        configuration: FilterConfigurationSnapshot(
            generation: 1, selectedVariant: .transformer,
            modelArtifactIdentity: identity, rules: [], categoryMappings: [:]
        )
    )
    await engine.handleSignalMemoryPressure()
    return result
}

@Test(arguments: [
    "不存在的消费也能制作报销凭证，完成付款后提供整套虚假交易材料。",
    "We manufacture receipts for purchases that never happened. Send payment to get matching documents for reimbursement claims.",
    "給付を申請するには端末の遠隔制御を許可し、銀行の支払操作をこちらに任せてください。",
    "培训入职课程要求先借贷购买名额，再招募付费学员才能退钱。",
    "Complete this training course by borrowing for enrolment and recruiting new paying trainees before any refund.",
    "研修の受講条件は借金して教材を買い、返金のために有料受講者を勧誘することです。"
])
private func businessWordsDoNotOverrideCorrectJunkPrediction(text: String) async {
    let result = await businessOverrideResult(text)
    #expect(result.fallbackReason == .none)
    #expect(result.systemAction == .junk)
}

private struct LegitimateBusinessFixture: Sendable {
    let text: String
    let label: String
}

@Test(arguments: [
    LegitimateBusinessFixture(text: "您的家庭财产保险理赔审核通过，赔付结果已记录在保单中。", label: "finance.insurance"),
    LegitimateBusinessFixture(text: "Your insurer approved the home-insurance claim; payment details are recorded in your policy.", label: "finance.insurance"),
    LegitimateBusinessFixture(text: "住宅保険の給付が承認され、指定口座への入金予定を保険会社に登録しました。", label: "finance.insurance"),
    LegitimateBusinessFixture(text: "员工内部培训课程请在周五完成，测验记录将计入员工档案。", label: "work.training"),
    LegitimateBusinessFixture(text: "Employees should complete the internal training course by Friday; quiz results go in the employee file.", label: "work.training"),
    LegitimateBusinessFixture(text: "社員向け社内研修を金曜までに受講してください。試験結果は社員台帳に反映します。", label: "work.training")
])
private func explicitBusinessContextStillCorrectsJunkPrediction(fixture: LegitimateBusinessFixture) async {
    let result = await businessOverrideResult(fixture.text)
    #expect(result.fallbackReason == .none)
    #expect(result.decision.labelID == fixture.label)
    #expect(result.systemAction == .transaction)
}

@Test(arguments: [
    LegitimateBusinessFixture(text: "药房账户本次登录验证码 483926，五分钟内有效，请在自己的应用中输入。", label: "verification"),
    LegitimateBusinessFixture(text: "Your prescription portal verification code is 483926. It expires in five minutes. Enter it in your own app.", label: "verification"),
    LegitimateBusinessFixture(text: "薬局アカウントの認証コードは483926です。5分間有効です。ご自身のアプリに入力してください。", label: "verification"),
    LegitimateBusinessFixture(text: "您的社会保险跨地区转移申请已完成，接收地将继续审核缴费年限。", label: "government.social_security"),
    LegitimateBusinessFixture(text: "Your social-insurance transfer application is being reviewed by the receiving office.", label: "government.social_security"),
    LegitimateBusinessFixture(text: "社会保険の移管手続きが完了しました。加入期間は受入窓口で引き続き確認します。", label: "government.social_security")
])
private func broadBusinessContextPreservesSpecificModelIntent(fixture: LegitimateBusinessFixture) async {
    let result = await businessOverrideResult(fixture.text, labelID: fixture.label)
    #expect(result.decision.labelID == fixture.label)
    #expect(result.systemAction == .transaction)
}

@Test(arguments: [
    "您的医院检查报告需要验证。把银行卡验证码 483926 发给我才能查看。",
    "Your pharmacy record is locked. Send me your bank verification code 483926 to unlock it.",
    "薬局の記録を解除するため、銀行の認証コード483926をこちらへ転送してください。"
])
private func medicalCredentialContextDoesNotForceNormal(text: String) async {
    let result = await businessOverrideResult(text)
    #expect(result.systemAction == .junk)
}

@Test(arguments: [
    "奖金已存入平台余额，提现前必须再缴保证金，先汇给私人账户才会放款。",
    "Your payroll bonus was credited on our platform, but withdrawal requires a release fee paid to a personal account first.",
    "賞与をプラットフォーム残高に入金しましたが、出金する前に解除手数料を個人口座へ払う必要があります。"
])
private func conditionalWithdrawalDoesNotOverrideCorrectJunkPrediction(text: String) async {
    let result = await businessOverrideResult(text)
    #expect(result.systemAction == .junk)
}

@Test(arguments: [
    "工资及季度奖金已发放至您的工资卡，入账流水可在银行应用中查询。",
    "Your salary and quarterly bonus were credited to your payroll account. The bank app shows the posted transaction.",
    "Your salary was deposited into your payroll account. You may withdraw it whenever you need to.",
    "給与と四半期賞与を給与口座へ入金しました。銀行アプリの明細で確認できます。"
])
private func settledPayrollStillHasIncomeIntent(text: String) async {
    let result = await businessOverrideResult(text)
    #expect(result.decision.labelID == "finance.income")
    #expect(result.systemAction == .transaction)
}

@Test(arguments: [
    "不支付封口费就向商户的顾客群散布虚假投诉，转账后才停止。",
    "Pay our silence fee or we send fabricated complaints to the merchant's customers. We stop only after payment.",
    "口止め料を支払わないと店舗の客に嘘の苦情を送ります。支払い後にだけ削除します。",
    "店舗に対する虚偽の告発を消すには支払いましたと返信してください。"
])
private func genericPaymentAndStoreWordsDoNotOverrideJunk(text: String) async {
    let result = await businessOverrideResult(text)
    #expect(result.systemAction == .junk)
}

@Test(arguments: [
    "账户尾号 4721 已完成商户扣款，交易明细请在银行应用中查看。",
    "Your account ending 4721 was debited for a merchant purchase. Details are available in your bank app.",
    "口座末尾4721から書店での購入代金が引き落とされました。銀行アプリで明細をご確認ください。"
])
private func postedMerchantDebitUsesConsumptionIntent(text: String) async {
    let result = await businessOverrideResult(text)
    #expect(result.decision.labelID == "finance.consumption")
    #expect(result.systemAction == .transaction)
}
#endif
