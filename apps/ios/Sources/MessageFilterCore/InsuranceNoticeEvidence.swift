import Foundation

/// Evidence for a benign insurance override, not a spam detector. A URL must
/// not establish the sender's business, and an access-fee mention is a reason
/// to defer to the learned classifier rather than assert a normal transaction.
struct InsuranceNoticeEvidence: Sendable {
    let prose: String
    let permitsBenignOverride: Bool
    let requiresLearnedDecision: Bool

    init(lowercasedBody body: String) {
        // Include bare ASCII domains as well as explicit links. Risk checks
        // below retain the original text, including CJK adjoining a URL.
        let prose = body.replacingOccurrences(
            of: #"(?<![a-z0-9_.-])(?:(?:https?://|www\.)[^\s<>"'（）()\[\]{},，。！？；：、]+|(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}(?::[0-9]{1,5})?(?:[/?#][^\s<>"'（）()\[\]{},，。！？；：、]+)?)"#,
            with: " ", options: .regularExpression
        )
        self.prose = prose
        let explicitInsurance = ["保险", "理赔", "赔付", "insurance", "insurer", "保険"]
            .contains(where: prose.contains)
        let policyClaim = prose.contains("claim") && prose.contains("policy") && prose.contains("coverage")
        let accessFeeLanguage = [
            "解锁费", "解冻费", "解冻款", "激活费", "释放费", "先交保证金",
            "unlock fee", "unlock charge", "unlocking charge", "unfreeze fee", "release fee",
            "activation fee", "activation charge", "advance fee",
            "凍結解除料", "解除手数料", "有効化手数料"
        ].contains(where: body.contains)
        // These describe payments to a representative, not a benefit paid
        // into the recipient's own account. They only disable an override.
        let representativePayment = body.range(
            of: #"\b(?:pay|send|wire|transfer)\b.{0,100}\bto\s+(?!your\b|own\b)(?:(?:the|an?|our|my|his|her|their)\s+)?(?:[a-z]+(?:'s)?\s+)?(?:personal|private)\s+(?:account|wallet)\b|(?:向|转给)(?:理赔员|客服|经办人|代理人|工作人员).{0,12}(?:私人|个人)|(?:担当者|係員|職員|代理人).{0,8}個人.{0,8}口座"#,
            options: .regularExpression
        ) != nil
        permitsBenignOverride = (explicitInsurance || policyClaim) && !accessFeeLanguage && !representativePayment
        requiresLearnedDecision = (explicitInsurance || policyClaim) && (accessFeeLanguage || representativePayment)
    }
}
