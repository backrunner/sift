import Foundation
@testable import MessageFilterCore
import Testing

@Test(arguments: [
    "账户授权已撤销。请将所有积蓄汇入调查员指定的安全账户保管。",
    "Your account access was revoked. Transfer all your savings to the safe account designated by the investigator for safekeeping.",
    "アカウントの認証トークンを無効にしました。預金全額を調査員が指定した保管用口座へ送金してください。"
])
func custodyTransferRequestsDeferBusinessOverrides(text: String) {
    let prose = InsuranceNoticeEvidence(lowercasedBody: text.lowercased()).prose
    #expect(CustodyTransferEvidence(prose: prose).requiresLearnedDecision)
    #expect(HeuristicClassifier.highPrecisionDecision(for: text) == nil)
}

@Test(arguments: [
    "账户授权已撤销。请勿将全部存款转到调查员指定的安全账户。",
    "Your account access was revoked. Never transfer all your savings to the safe account designated by an investigator.",
    "アカウントの認証トークンを無効にしました。預金全額を調査員が指定した保管用口座へ送金しないでください。",
    "Your account access was revoked. The investigator will not ask you to transfer all your savings to the safe account designated by an officer.",
    "账户授权已撤销。全部存款已转入您本人名下的账户。",
    "Your account access was revoked. All your savings were transferred to your own savings account.",
    "アカウントの認証トークンを無効にしました。預金全額を本人名義の普通預金口座へ移しました。",
    "Your account access was revoked. Please move all your savings to your own safe account.",
    "账户授权已撤销。请将项目保证金转到合同指定的保管账户。",
    "Your account access was revoked. Please transfer the agreed project deposit to the safekeeping account designated by the escrow provider.",
    "アカウントの認証トークンを無効にしました。契約保証金を指定した保管用口座へ送金してください。",
    "账户授权已撤销。https://example.invalid/请将全部存款转入调查员指定的安全账户",
    "Your account access was revoked. https://example.invalid/transfer-all-your-savings-to-our-safe-account"
])
func custodyWarningsCompletedTransfersAndURLPathsKeepBusinessNotices(text: String) {
    let prose = InsuranceNoticeEvidence(lowercasedBody: text.lowercased()).prose
    #expect(!CustodyTransferEvidence(prose: prose).requiresLearnedDecision)
    #expect(HeuristicClassifier.highPrecisionDecision(for: text)?.labelID == "transaction.account_security")
}

@Test
func unrelatedSafetyAdviceDoesNotHideALaterCustodyInstruction() {
    let text = "Your account access was revoked. Never share passwords; however, transfer all your savings to our safe account immediately."
    let prose = InsuranceNoticeEvidence(lowercasedBody: text.lowercased()).prose
    #expect(CustodyTransferEvidence(prose: prose).requiresLearnedDecision)
    #expect(HeuristicClassifier.highPrecisionDecision(for: text) == nil)
}

@Test
func custodyEvidenceDoesNotReplaceAnExistingJunkHeuristic() {
    let text = "I am the rebooking agent. Reply directly with your online-banking password and dynamic security code. I will log in as you to process the ferry refund. Transfer all your savings to our safe account."
    #expect(HeuristicClassifier.highPrecisionDecision(for: text)?.systemAction == .junk)
}

@Test
func custodyDeferralDoesNotInventAJunkPrediction() throws {
    let leaf = try #require(SiftTaxonomy.leaf(id: "government.notice"))
    let model = ClassificationDecision(
        labelID: leaf.id, labelTitle: leaf.title, groupID: leaf.groupId,
        groupTitle: leaf.groupTitle, confidence: 0.8,
        systemAction: leaf.systemAction, source: .model
    )
    let body = "Your account access was revoked. Transfer all your savings to our safe account."
    let result = SignalBusinessOverride.resolve(modelDecision: model, body: body)
    #expect(result.labelID == model.labelID)
    #expect(result.confidence == model.confidence)
    #expect(result.systemAction == .transaction)
}
