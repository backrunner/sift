import Foundation
@testable import MessageFilterCore
import Testing

@Test(arguments: [
    "按您的设置，信用卡境外线下交易功能已关闭，境内用卡不受影响。您可在已登录的银行应用查看本次设置记录。",
    "As requested, overseas in-person spending is disabled on your credit card. Domestic use is unchanged. Review the setting in your signed-in banking app.",
    "ご依頼によりクレジットカードの海外での決済を停止しました。国内での利用は変わりません。ログイン済みの銀行アプリで設定をご確認ください。",
    "您申请的信用卡电子账单已生效，纸质账单从下一期停止寄送。设置回执可查看。",
    "Your request for electronic credit-card statements is active. Paper statements will stop from the next cycle. Setting receipt is ready.",
    "お申し込みのクレジットカード電子明細が有効になりました。紙の明細は次回から停止します。設定の記録はこちらです。"
])
func completedCardSettingsHaveSpecificCorroboration(text: String) {
    let prose = InsuranceNoticeEvidence(lowercasedBody: text.lowercased()).prose
    #expect(AccountSettingsEvidence(prose: prose).decision?.labelID == "finance.credit_card")
    #expect(HeuristicClassifier.highPrecisionDecision(for: text)?.systemAction == .transaction)
}

@Test(arguments: [
    "您在账户设置中生成了新的备用恢复码，旧恢复码已失效。请自行离线保存新码，客服不会要求您回复任何完整恢复码。",
    "You generated new backup recovery codes in account settings. Old codes are invalid. Keep the new codes offline. Never send the codes to support.",
    "アカウント設定で予備の復旧コードを再発行し、旧コードは無効になりました。新コードはご自身でオフライン保管し、係員へ送らないでください。"
])
func recoveryCodesForOwnOfflineStorageAreNotifications(text: String) {
    let prose = InsuranceNoticeEvidence(lowercasedBody: text.lowercased()).prose
    #expect(AccountSettingsEvidence(prose: prose).decision?.labelID == "transaction.account_security")
    #expect(HeuristicClassifier.highPrecisionDecision(for: text)?.systemAction == .transaction)
}

@Test(arguments: [
    "I am considering electronic credit-card statements; how do I enable them?",
    "Your credit card is disabled. Please contact support.",
    "Credit-card electronic statements are on sale. Buy the optional service.",
    "アカウントの復旧コードの保存方法を考えています。まだ再発行していません。",
    "Please read this: https://example.invalid/as-requested-overseas-spending-disabled-credit-card-domestic-unchanged-signed-in-banking-app",
    "Card details: https://example.invalid/您申请的信用卡电子账单已生效，纸质账单下期停止寄送"
])
func intentionOrURLKeywordsDoNotEstablishCompletedSettings(text: String) {
    let prose = InsuranceNoticeEvidence(lowercasedBody: text.lowercased()).prose
    #expect(AccountSettingsEvidence(prose: prose).decision == nil)
}

@Test(arguments: [
    "Reply with your bank verification code to support.",
    "Never share a password. However, paste your recovery codes into this support form.",
    "We never ask for passwords, reply with your recovery codes to support.",
    "We never ask for passwords and reply with your recovery codes to support.",
    "无需提供密码，只需回复完整恢复码给客服。",
    "パスワードは求めませんが、復旧コードをこのフォームへ貼り付けてください。",
    "Install remote-control software so our agent can operate your bank screen.",
    "Transfer all your savings to our safe account.",
    "Send an unlocking deposit to the technician's private account.",
    "请把完整恢复码发给客服。",
    "请先转账至个人账户缴纳保证金。",
    "復旧コードをこのフォームへ貼り付けてください。",
    "遠隔操作ソフトをインストールしてください。"
])
func completedSettingPrefixCannotAuthorizeALaterRiskRequest(suffix: String) {
    let text = "Your request for electronic credit-card statements is active. Paper statements will stop next month. " + suffix
    #expect(AccountSettingsEvidence(prose: text.lowercased()).decision == nil)
}

@Test
func newSettingEvidenceCannotReplaceAnExistingJunkRule() {
    let text = "Your request for electronic credit-card statements is active. Paper statements will stop next month. I am the rebooking agent. Reply directly with your online-banking password and dynamic security code. I will log in as you to process the ferry refund."
    #expect(HeuristicClassifier.highPrecisionDecision(for: text)?.systemAction == .junk)
}
