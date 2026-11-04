import Foundation

/// A completed security change must name the security object being changed.
/// Generic removal/cancellation plus an unrelated account is not sufficient.
struct AccountSecurityCompletionEvidence: Sendable {
    let isCompletedNotice: Bool

    init(prose: String) {
        let clauses = prose.replacingOccurrences(
            of: #"\b(?:but|however|instead)\b|但是|不过|ただし|しかし"#,
            with: "\n", options: .regularExpression
        ).components(separatedBy: CharacterSet(charactersIn: ".!?;,。！？；，\n"))
        func matches(_ text: String, _ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        let denied = #"\b(?:do not|don't|never|has not|have not|was not|not yet|will be|will revoke|will remove|please remove|please revoke)\b|尚未|还未|没有|未曾|不要|请勿|将会|准备|请撤销|请删除|まだ.{0,12}(?:ません|ない)|しないで|していません|する予定"#
        let completed = clauses.contains { clause in
            guard !matches(clause, denied) else { return false }
            return matches(clause, #"(?:设备|访问令牌|浏览器令牌|账户授权|账号授权|设备授权|会话|访问权限)(?:已经|已)(?:被)?(?:移除|删除|撤销|注销|终止|失效)|(?:已|已经)(?:移除|删除|撤销)(?:了)?(?:旧|该|此|您的|你的)?(?:设备|访问令牌|浏览器令牌|账户授权|访问权限)|(?:设备|端末).{0,12}(?:不能再访问|不再访问个人资料)|安全验证已通过|二段階認証が有効"#)
                || matches(clause, #"\b(?:account access|account authorization|device authorization|access token|browser token|session|device)\b.{0,25}\b(?:was |has been |is now )?(?:removed|revoked|invalidated|disabled|signed out)\b|\b(?:removed|revoked|invalidated) (?:the |a |an |your |old )*(?:device|browser token|access token|account access|account authorization)\b|\bdevice\b.{0,32}\b(?:can no longer|cannot) access (?:your |the )?profile\b|\bsecurity center ended access for (?:an? |the |old )*(?:tablet|device|browser)\b|\btwo-step verification is now on\b"#)
                || matches(clause, #"(?:認証トークン|アクセストークン|端末|アカウント権限|アクセス権限)(?:を|が).{0,12}(?:削除されました|削除しました|削除したため|無効にしました|終了しました|取り消しました)|端末からプロフィールへアクセスできません|(?:アカウント|セッション).{0,12}ログアウトしました"#)
        }
        let privatePaymentRequest = clauses.contains { clause in
            guard !matches(clause, #"\b(?:do not|don't|never|no need to|will not|won't|must not)\b|不要|请勿|无需|不会|切勿|振り込まない|送金しない|求めません"#) else { return false }
            let personalRecipient = matches(clause, #"\b(?:private|personal) account\b|私人账户|个人账户|個人(?:の)?口座"#)
            let instruction = matches(clause, #"(?:^|\b(?:first|please|must|need to|required to))\s*(?:pay|transfer|send|deposit)\b|(?:请|先|必须|需要).{0,30}(?:转|汇|缴|支付)|(?:振り込んで|送金して|支払って|払って)ください"#)
            return personalRecipient && instruction
        }
        isCompletedNotice = completed && !privatePaymentRequest
    }
}
