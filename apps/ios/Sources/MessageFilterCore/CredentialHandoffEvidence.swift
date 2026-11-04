import Foundation

/// A reason to defer a business override to the model, not a spam classifier.
/// Requires a secret, a transmission request and an external recipient in
/// the same clause. Negated safety advice does not establish a handoff.
struct CredentialHandoffEvidence: Sendable {
    let requiresLearnedDecision: Bool

    init(prose: String) {
        let claimedRefund = prose.range(
            of: #"\b(?:refund|payout|compensation)\b|退款|退费|理赔|赔款|返金|保険金"#,
            options: .regularExpression
        ) != nil
        let separated = prose.replacingOccurrences(
            of: #"\b(?:but|however|instead)\b|但是|不过|ただし|しかし"#,
            with: "\n", options: .regularExpression
        )
        requiresLearnedDecision = separated.components(separatedBy: CharacterSet(charactersIn: ".!?;。！？；\n"))
            .contains { clause in
                func matches(_ pattern: String) -> Bool {
                    clause.range(of: pattern, options: .regularExpression) != nil
                }
                let negated = matches(#"\b(?:do not|don't|never|no need to|must not|should not|will not|won't|does not|not required to)\b|不会|不要|请勿|无需|切勿|不得|送らない|送信しない|返信しない|渡さない|伝えない|求めません|求めることはありません|不要です|必要はありません"#)
                guard !negated else { return false }
                let redemptionDemand = claimedRefund
                    && matches(#"\b(?:gift|top-up|prepaid) cards?\b|充值卡|礼品卡|プリペイドカード|ギフトカード"#)
                    && matches(#"\b(?:first|please|must|need to|required to) (?:buy|purchase)\b|先.{0,10}(?:买|购买)|先に.{0,24}(?:買|購入)"#)
                    && matches(#"\b(?:redemption|secret) codes?\b|卡密|兑换码|秘密番号|交換コード|引き換えコード"#)
                let secret = redemptionDemand
                    || matches(#"\b(?:one[- ]time (?:password|code)|(?:bank|banking|card) (?:payment )?(?:pin|password|verification code)|master (?:secret|key)|private key|recovery (?:phrase|codes?))\b|银行卡密码|银行密码|银行验证码|动态验证码|动态口令|完整恢复码|恢复短语|主密钥|私钥|ワンタイムコード|ワンタイムパスワード|銀行の暗証番号|銀行のパスワード|復旧コード|秘密鍵"#)
                    || matches(#"\b(?:payment|wallet|mobile-payment|electronic-wallet)\b.{0,40}\b(?:password|(?:sign-in|login).{0,15}(?:code|passcode|digits))\b|(?:支付账户|付款账户|支付应用|电子钱包|手机支付).{0,30}(?:登录密码|登录口令|验证码|动态口令)|(?:決済|電子ウォレット|携帯決済|ネット銀行).{0,35}(?:ログイン|認証).{0,12}(?:パスワード|コード|合言葉|数字)|復元フレーズ"#)
                guard secret else { return false }
                let transmission = matches(#"\b(?:send|give|tell|reply|forward|paste|provide|submit|share|upload)\b|\bread (?:out|aloud)\b|发送|发给|提供|回复|回传|提交|粘贴|告知|念给|上传|送って|送信|返信|貼り付け|伝えて|渡して|読み上げ"#)
                let recipient = matches(#"\breply\b|\b(?:to|with)\s+(?:(?:this|the|our|your|a|an)\s+)?(?:(?:bank|support|customer.service|shop|rental|claims|subsidy|print)\s+)?(?:agent|support|staff|technician|engineer|representative|administrator|accountant|operator|handler|clerk|assistant|mechanic|repairer|foreman|inspector|adviser|adjuster|officer|librarian|mixer|captioner|sailmaker|locksmith)\b|\b(?:give|tell|send)\s+(?:(?:this|the|our|your)\s+)?(?:agent|support|technician|engineer|operator|us|me)\b|\b(?:into|in|to)\s+(?:this|our|the)\s+(?:(?:support|verification)\s+)?(?:form|chat)\b|(?:给|向|到|至|告知)(?:本|人工|在线|指定|门店)?(?:客服|工作人员|技术员|经办人|管理员|专员|店员|师傅|修理员|技师|工程师|顾问|工头|理赔员|表单|聊天)|(?:担当者|係員|サポート|窓口|技術員|職員|管理人|相談員|技師|修理員|職長|このフォーム|このチャット)(?:へ|に)"#)
                return transmission && recipient
            }
    }
}
