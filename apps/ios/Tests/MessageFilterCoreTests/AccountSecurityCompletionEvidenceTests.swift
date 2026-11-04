import Foundation
@testable import MessageFilterCore
import Testing

@Test(arguments: [
    "账户授权已撤销。请在应用内查看设备列表。",
    "You removed a device from the account, so it can no longer access your profile.",
    "Security center revoked the old browser token; a fresh session will require verification.",
    "Your account access was revoked. Never transfer money to a private account.",
    "アカウントの認証トークンを無効にしました。新しい端末では再認証が必要です。"
])
func completedSecurityObjectsRetainTheirNotifications(text: String) {
    #expect(AccountSecurityCompletionEvidence(prose: text.lowercased()).isCompletedNotice)
    #expect(HeuristicClassifier.highPrecisionDecision(for: text)?.labelID == "transaction.account_security")
}

@Test(arguments: [
    "仓储罚款可以撤销，先向管理员私人账户转保证金，到账才清除欠款。",
    "A penalty will be removed after you send a deposit to the custodian's private account.",
    "延滞金を取り消します。先に担当者個人の口座へ保証金を振り込んでください。",
    "The debt was removed from the ledger. This is not an account access change.",
    "Please revoke the browser token in account settings.",
    "Your account access has not been revoked.",
    "账户授权尚未撤销，请先阅读说明。",
    "アカウントの認証トークンはまだ無効にしていません。",
    "Please read https://example.invalid/account-access-was-revoked"
])
func CancellationAndRequestsAreNotCompletedSecurityChanges(text: String) {
    let prose = InsuranceNoticeEvidence(lowercasedBody: text.lowercased()).prose
    #expect(!AccountSecurityCompletionEvidence(prose: prose).isCompletedNotice)
    #expect(HeuristicClassifier.highPrecisionDecision(for: text)?.labelID != "transaction.account_security")
}

@Test(arguments: [
    "账户授权已撤销。请先向工作人员私人账户支付恢复费用。",
    "Your account access was revoked. First pay a restore fee to the clerk's private account.",
    "アカウントの認証トークンを無効にしました。先に担当者個人の口座へ送金してください。"
])
func completedSecurityPrefixCannotAuthorizePrivatePayment(text: String) {
    #expect(!AccountSecurityCompletionEvidence(prose: text.lowercased()).isCompletedNotice)
    #expect(HeuristicClassifier.highPrecisionDecision(for: text)?.labelID != "transaction.account_security")
}
