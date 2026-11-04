import Foundation
@testable import MessageFilterCore
import Testing

@Test(arguments: [
    "请将支付账户刚收到的动态口令回复给管理员，由管理员登录完成确认。",
    "请把电子钱包登录密码告知门店技师，由技师代操作退款。",
    "Send the mobile-payment login password to the shop technician for a refund.",
    "Reply with the payment app's sign-in verification digits to the rental clerk.",
    "Read out your mobile-payment login password to the technician.",
    "決済口座のログインパスワードを管理人へ送ってください。代理で確認します。",
    "Your compensation is ready. First buy top-up cards and send their secret codes to the adjuster; the payout follows redemption.",
    "理赔款已分配，先购买充值卡并把卡密发给理赔员，核销后才支付赔款。",
    "保険金を受け取るには先にプリペイドカードを買い、秘密番号を担当者へ送ってください。使用後に支払います。"
])
func financialLoginAndConditionalRedemptionRequestsDeferBusinessTrust(text: String) {
    #expect(CredentialHandoffEvidence(prose: text.lowercased()).requiresLearnedDecision)
}

@Test(arguments: [
    "退款已到账。无需发送动态口令给管理员。",
    "Never send your electronic-wallet login password to a shop technician.",
    "決済口座のログインパスワードを管理人へ送らないでください。",
    "Your refund is approved. Do not buy gift cards or send redemption codes to a claims officer.",
    "The gift-card refund is complete. Please send the receipt number to the clerk.",
    "Read the instructions about protecting your private key in this support chat.",
    "Please buy a gift card as a birthday present and give its code to your friend.",
    "在您本人设备的钱包应用中输入恢复短语，不要交给工作人员。",
    "Enter your wallet recovery phrase on your own device, never send it to staff.",
    "Please read https://example.invalid/first-buy-gift-cards-send-secret-codes-to-the-adjuster-refund"
])
func financialSafetyAdviceAndOwnUseDoNotBecomeCredentialHandoffs(text: String) {
    let prose = InsuranceNoticeEvidence(lowercasedBody: text.lowercased()).prose
    #expect(!CredentialHandoffEvidence(prose: prose).requiresLearnedDecision)
}

@Test(arguments: [
    "设备授权已撤销。请将主密钥粘贴到客服表单，我们代您重建访问令牌。",
    "We do not ask for your project password. To restore revoked access, paste the complete administrator master secret into this support form so we can issue a token for you.",
    "留守番電話の再設定には支払確認が必要です。銀行から届くワンタイムコードをそのまま担当者へ返信してください。",
    "Account access was revoked. Send your one-time code to our support agent to restore it.",
    "语音信箱有未接来电。请把银行验证码回复给本客服，由我们处理呼叫记录。",
    "アカウントの認証トークンを無効にしました。復旧コードをこのフォームへ貼り付けてください。"
])
func credentialRequestsCannotForceBusinessOverrides(text: String) {
    let evidence = InsuranceNoticeEvidence(lowercasedBody: text.lowercased())
    #expect(CredentialHandoffEvidence(prose: evidence.prose).requiresLearnedDecision)
    #expect(HeuristicClassifier.highPrecisionDecision(for: text) == nil)
}

@Test(arguments: [
    "账户访问令牌已撤销。请勿把主密钥发给客服，工作人员不会索取主密钥。",
    "The device was removed from your account. Never send a one-time code to our support agent.",
    "アカウントの認証トークンを無効にしました。復旧コードを担当者へ送らないでください。",
    "Enter your one-time code in your own banking app. No support agent needs it.",
    "账户授权已撤销。发送工单号码给客服即可，不要发送银行验证码。",
    "Missed call from the office; left no voicemail. https://example.invalid/send-one-time-code-to-support-agent"
])
func credentialSafetyAdviceAndURLPathsDoNotCreateHandoffs(text: String) {
    let prose = InsuranceNoticeEvidence(lowercasedBody: text.lowercased()).prose
    #expect(!CredentialHandoffEvidence(prose: prose).requiresLearnedDecision)
}

@Test
func safetySentenceCannotAuthorizeASubsequentSecretRequest() {
    let text = "Account token revoked. Never send a bank password to anyone. However, send your one-time code to our support agent now."
    #expect(CredentialHandoffEvidence(prose: text.lowercased()).requiresLearnedDecision)
    #expect(HeuristicClassifier.highPrecisionDecision(for: text) == nil)
}

@Test
func credentialHandoffDoesNotDisableAnExistingJunkHeuristic() {
    let text = "I am the rebooking agent. Reply directly with your online-banking password and dynamic security code. I will log in as you to process the ferry refund."
    #expect(HeuristicClassifier.highPrecisionDecision(for: text)?.systemAction == .junk)
}
