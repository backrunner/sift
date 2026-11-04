import Foundation

/// A wage-related payment demand is not evidence that wages have arrived.
/// This only disables the income override; it never creates a junk decision.
enum IncomeNoticeEvidence {
    static func requiresLearnedDecision(_ body: String) -> Bool {
        let prose = body.lowercased().replacingOccurrences(
            of: #"(?<![a-z0-9_.-])(?:(?:https?://|www\.)[^\s<>"'（）()\[\]{},，。！？；：、]+|(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}(?::[0-9]{1,5})?(?:[/?#][^\s<>"'（）()\[\]{},，。！？；：、]+)?)"#,
            with: " ", options: .regularExpression
        )
        let clauses = prose.components(separatedBy: CharacterSet(charactersIn: ".!?。！？\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        func isAdviceOrDenial(_ text: String) -> Bool {
            contains(text, [
                "请勿", "切勿", "警惕", "无需", "不需要", "不会要求", "不要支付", "不要转账",
                "do not pay", "do not transfer", "don't pay", "don't transfer", "never pay",
                "never transfer", "will not ask", "never ask", "beware of", "warning about",
                "not required", "no deposit", "no fee", "no need to pay", "without paying",
                "支払わない", "振り込まない", "送金しない", "求めません", "要求しません",
                "必要ありません", "不要", "詐欺に注意", "要求することはありません"
            ])
        }

        func hasIncome(_ text: String) -> Bool {
            contains(text, ["工资", "薪资", "薪酬", "奖金", "給与", "賃金", "報酬"])
                || matches(text, #"\b(?:salary|payroll|backpay|wages?|earnings|bonus)\b"#)
        }

        func hasPrivatePaymentRequest(_ text: String) -> Bool {
            guard !isAdviceOrDenial(text) else { return false }
            return matches(text, #"\b(?:pay|send|wire|transfer)\b.{0,110}\bto\s+(?!(?:your|my|own)\b)(?:[a-z]+(?:'s)?\s+){0,5}(?:personal|private)\s+(?:bank\s+)?(?:account|wallet)\b"#)
                || matches(text, #"(?:向|转到|转给|支付到|汇到|汇入)(?!您|你|自己).{0,24}(?:私人|个人)(?:的)?(?:银行)?(?:账户|账号|钱包|收款码)"#)
                || matches(text, #"(?:担当者|係員|職員|代理人|審査員).{0,8}個人(?:名義)?の?口座.{0,18}(?:振り込んで|送金して|支払って)"#)
        }

        for (index, clause) in clauses.enumerated() {
            guard !isAdviceOrDenial(clause), contains(clause, [
                "保证金", "解冻费", "解锁费", "核验费", "放行费",
                "identity deposit", "verification deposit", "security deposit", "unfreezing fee",
                "unfreeze fee", "unlock fee", "release fee", "processing fee",
                "保証金", "解除手数料", "凍結解除料", "本人確認料"
            ]), contains(clause, ["先", "才", "之前", "first", "before", "only after", "until", "事前", "支給前"]),
            contains(clause, ["支付", "交", "转", "汇", "pay", "send", "wire", "transfer", "支払", "振り込", "送金", "必要"])
            else { continue }

            // Link the demand to wages in this clause or a directly preceding
            // blocked-wage statement, not to unrelated rent after a pay notice.
            let prior = index > 0 ? clauses[index - 1] : ""
            let blockedIncome = !isAdviceOrDenial(prior) && hasIncome(prior) && contains(prior, [
                "冻结", "锁定", "待领取", "暂扣", "frozen", "locked", "on hold", "withheld",
                "not yet paid", "凍結", "保留", "未支給"
            ])
            guard hasIncome(clause) || blockedIncome else { continue }
            if hasPrivatePaymentRequest(clause) { return true }
            if index + 1 < clauses.count, hasPrivatePaymentRequest(clauses[index + 1]) { return true }
        }
        return false
    }

    private static func contains(_ text: String, _ terms: [String]) -> Bool {
        terms.contains(where: text.contains)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
