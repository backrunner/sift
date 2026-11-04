import Foundation

/// Defers a business override when a message orders all funds into a third
/// party's purported safekeeping account. This does not assign a spam label.
struct CustodyTransferEvidence: Sendable {
    let requiresLearnedDecision: Bool

    init(prose: String) {
        let separated = prose.replacingOccurrences(
            of: #"\b(?:but|however|instead)\b[,，]?|但是|不过|ただし|しかし"#,
            with: "\n", options: .regularExpression
        )
        requiresLearnedDecision = separated.components(separatedBy: CharacterSet(charactersIn: ".!?;。！？；\n"))
            .contains { clause in
                func matches(_ pattern: String) -> Bool {
                    clause.range(of: pattern, options: .regularExpression) != nil
                }
                let negated = matches(#"\b(?:do not|don't|never|no need to|must not|should not|will not|won't|does not|not required to|beware of|warning about)\b|不会|不要|请勿|无需|切勿|不得|不必|不需要|振り込まない|送金しない|移さない|求めません|求めることはありません|必要はありません"#)
                guard !negated else { return false }
                let allFunds = matches(#"\ball (?:of )?(?:your |the )?(?:savings|funds|money)\b|\b(?:your |the )?entire (?:account )?balance\b|全部(?:存款|资金|积蓄)|所有(?:存款|资金|积蓄)|全額|全財産"#)
                guard allFunds else { return false }
                let direction = matches(#"(?:请|必须|需要|务必|立即|马上).{0,70}(?:转到|转入|转至|汇入|汇至)|(?:^|\b(?:please|must|need to|required to))\s*(?:transfer|send|move)\b|(?:振り込んで|送金して|移して)ください"#)
                let externalCustody = matches(#"(?:转到|转入|转至|汇入|汇至).{0,24}指定的?(?:安全|保管)账户|\b(?:to|into) (?:the )?(?:safe|safekeeping) account (?:specified|designated|provided|controlled) by\b|\b(?:to|into) our (?:safe|safekeeping) account\b|指定.{0,12}(?:安全口座|保管用口座)(?:へ|に)"#)
                return direction && externalCustody
            }
    }
}
