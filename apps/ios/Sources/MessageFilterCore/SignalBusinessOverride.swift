import Foundation

/// A business-domain keyword is not sufficient evidence to dismiss a learned
/// junk result when the message also instructs a sensitive or illicit action.
/// This only vetoes a transactional/promotional override; it never creates junk
/// from a non-junk prediction or changes the classifier's confidence threshold.
enum SignalBusinessOverride {
    static func resolve(
        modelDecision: ClassificationDecision,
        body: String
    ) -> ClassificationDecision {
        guard let business = HeuristicClassifier.highPrecisionDecision(for: body) else {
            return modelDecision
        }
        let validated = ModelOutputContract.validatedDecision(modelDecision, minimumConfidence: 0.5)
        if validated.labelID == "spam", validated.systemAction == .junk,
           business.systemAction == .transaction || business.systemAction == .promotion,
           hasExplicitRiskInstruction(body) {
            return modelDecision
        }
        return business
    }

    private static func hasExplicitRiskInstruction(_ body: String) -> Bool {
        let prose = body.lowercased().replacingOccurrences(
            of: #"(?<![a-z0-9])(?:https?://|www\.)[^\s<>"'（）()\[\]{},，。！？；：、]+"#,
            with: " ", options: .regularExpression
        )
        let clauses = prose.components(separatedBy: CharacterSet(charactersIn: ".!?。！？\n"))
        return clauses.contains { clause in
            // Keep denials/advice in their own clause. An unrelated warning in
            // an earlier sentence does not license a later disclosure request.
            guard !containsAny(clause, [
                "不要", "请勿", "不会", "无需提供", "无需回复", "无需发送", "无需转账", "不得", "切勿", "不能发送",
                "do not ", "don't ", "never ", "will not ", "won't ", "does not ", "must not ", "should not ",
                "beware of ", "warning about ", "do not sell", "not for sale",
                "送らない", "送信しない", "返信しない", "教えない", "求めません",
                "求めることはありません", "要求しません", "要求することはありません",
                "販売しません", "販売していません", "販売禁止", "販売はしません"
            ]) else { return false }

            let credential = containsAny(clause, [
                "网银密码", "网银口令", "登录密码", "银行卡密码", "卡片安全码", "安全码",
                "恢复代码", "恢复码", "password", "card pin", "recovery code", "seed phrase",
                "security code", "sms login code", "パスワード", "暗証番号", "復旧コード",
                "リカバリーコード", "セキュリティコード"
            ])
            let disclosure = containsAny(clause, [
                "发给我", "发送给我", "发给客服", "转发给", "回复", "发给工作人员",
                "reply with", "send me", "send us", "forward to", "send your", "send the",
                "返信してください", "送ってください", "送信してください", "送り", "教えてください"
            ])
            if credential && disclosure { return true }

            let funds = containsAny(clause, [
                "提现", "领款", "奖金", "中奖", "withdraw", "dividend", "prize", "winnings",
                "出金", "引き出", "賞金", "当選金"
            ])
            let condition = containsAny(clause, [
                "先", "前", "才", "first", "before", "only then", "まで", "ないと"
            ])
            let privateOrReleaseCharge = containsAny(clause, [
                "私人账户", "个人账户", "解冻费", "解冻手续费", "放行费", "pay me",
                "personal account", "private account", "unfreezing fee", "release fee",
                "個人口座", "解除手数料", "凍結解除料"
            ])
            if funds && condition && privateOrReleaseCharge { return true }

            // Withholding a person's own deposited principal until they recruit
            // paying members is different from an ordinary referral reward.
            // Require all parts in the same clause, outside URLs and advice.
            let principal = containsAny(clause, [
                "本金", "deposited principal", "own principal", "original deposit", "元金", "元本"
            ])
            let paidRecruitment = containsAny(clause, [
                "招募付费", "招募新的付费", "拉付费", "发展付费",
                "recruit paying", "recruiting paying", "recruit new paying", "recruiting new paying",
                "有料会員を勧誘", "有料受講者を勧誘"
            ])
            let releaseConditionalOnRecruitment = containsAny(clause, [
                "才可", "才能", "只有", "必须", "only after", "only if", "unless", "until you recruit",
                "しない限り", "勧誘しないと", "勧誘するまで"
            ])
            let recruitmentNotRequired = containsAny(clause, [
                "无需招募", "不需要招募", "不必招募", "without recruiting", "without having to recruit",
                "no need to recruit", "勧誘は不要", "勧誘する必要はありません", "勧誘する必要がありません"
            ])
            let unconditionalPrincipalAccess = clause.range(
                of: #"本金(?:可以|可)?随时(?:提现|提取)|(?:principal|original deposit) (?:is available|can be withdrawn|may be withdrawn).*at any time|(?:元金|元本)はいつでも引き出"#,
                options: .regularExpression
            ) != nil
            if funds && principal && paidRecruitment && releaseConditionalOnRecruitment
                && !recruitmentNotRequired && !unconditionalPrincipalAccess {
                return true
            }

            let prohibitedDrug = containsAny(clause, [
                "违禁兴奋剂", "违禁药物", "违禁药品", "banned stimulants", "banned drugs",
                "illegal drugs", "禁止薬物", "違法薬物"
            ])
            let sale = containsAny(clause, ["可买", "出售", "销售", "for sale", "selling", "販売します", "販売中"])
            return prohibitedDrug && sale
        }
    }

    private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains(where: text.contains)
    }
}
