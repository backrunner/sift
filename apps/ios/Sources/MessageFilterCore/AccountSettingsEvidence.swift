import Foundation

/// Completed self-service settings with corroborating state details. Used only
/// when existing high-precision rules have no decision; URLs supply no evidence.
struct AccountSettingsEvidence: Sendable {
    let decision: ClassificationDecision?

    init(prose: String) {
        func matches(_ pattern: String) -> Bool {
            prose.range(of: pattern, options: .regularExpression) != nil
        }
        guard matches(#"信用卡|credit.card|クレジットカード|恢复码|recovery codes|復旧コード"#) else {
            decision = nil
            return
        }
        let clauses = prose.replacingOccurrences(
            of: #"\b(?:but|however|instead|and|then|just)\b|但是|不过|而是|只需|只要|同时|然后|ただし|しかし|そして|ですが"#,
            with: "\n", options: .regularExpression
        ).components(separatedBy: CharacterSet(charactersIn: ".!?;,。！？；，、\n"))
        let positiveRequest = clauses.contains { clause in
            let negated = clause.range(
                of: #"\b(?:do not|don't|never|will not|won't|must not|should not|no need to)\b|不会|不要|请勿|无需|切勿|不得|送らない|送信しない|返信しない|求めません|要求しません|必要はありません"#,
                options: .regularExpression
            ) != nil
            return !negated && clause.range(
                of: #"\b(?:send|give|reply|paste|provide|share|transfer|pay|install)\b|发送|发给|回复|回传|提交|粘贴|提供|转账|汇款|缴费|付费|安装|送って|送信して|返信して|貼り付けて|伝えて|振り込んで|送金して|支払って|インストール"#,
                options: .regularExpression
            ) != nil
        }
        let riskyContext = matches(#"remote[- ]control|screen[- ]shar|personal account|private account|gift cards?|unlock.{0,12}(?:fee|deposit)|unfreez.{0,12}(?:fee|charge)|远程控制|屏幕共享|私人账户|个人账户|保证金|解冻费|礼品卡|遠隔操作|画面共有|個人口座|保証金|解除手数料|ギフトカード"#)
        guard !positiveRequest, !riskyContext,
              !CredentialHandoffEvidence(prose: prose).requiresLearnedDecision,
              !CustodyTransferEvidence(prose: prose).requiresLearnedDecision else {
            decision = nil
            return
        }

        let requested = matches(#"按您的设置|按您的申请|您申请|as requested|your request|ご依頼|ご希望|お申し込み"#)
        let card = matches(#"信用卡|credit.card|クレジットカード"#)
        let spendingDisabled = matches(#"境外.{0,16}(?:交易|消费).{0,8}(?:已关闭|已停用)|(?:overseas|international).{0,20}(?:spending|payments|transactions).{0,20}(?:disabled|turned off)|海外.{0,16}(?:利用|決済|取引).{0,12}(?:停止しました|無効にしました)"#)
        let domesticUnchanged = matches(#"境内.{0,12}(?:不受影响|不变)|domestic.{0,16}unchanged|国内.{0,12}(?:変わりません|変更はありません)"#)
        let authenticatedApp = matches(#"已登录的银行应用|signed.in banking app|ログイン済みの銀行アプリ"#)
        let electronicStatements = matches(#"电子.{0,4}账单|electronic.{0,20}statements|電子明細"#)
        let activated = matches(#"已生效|已启用|is active|有効になりました|設定が完了"#)
        let paperEnding = matches(#"纸质.{0,4}账单.{0,20}(?:停止|不再)|paper statements will stop|紙の明細.{0,20}(?:終了|停止)"#)
        let accountSettings = matches(#"账户设置|account settings|アカウント設定"#)
        let regenerated = matches(#"生成了新的.{0,8}恢复码|(?:generated|regenerated).{0,30}(?:backup )?recovery codes|復旧コードを再発行"#)
        let oldInvalid = matches(#"旧恢复码已失效|old codes.{0,12}(?:invalid|inactive)|旧コードは無効"#)
        let ownOffline = matches(#"自行离线保存|store.{0,16}(?:yourself )?offline|keep.{0,16}(?:yourself )?offline|ご自身でオフライン保管"#)

        let label: String?
        if requested && card && spendingDisabled && domesticUnchanged && authenticatedApp {
            label = "finance.credit_card"
        } else if requested && card && electronicStatements && activated && paperEnding {
            label = "finance.credit_card"
        } else if accountSettings && regenerated && oldInvalid && ownOffline {
            label = "transaction.account_security"
        } else {
            label = nil
        }
        if let label, let leaf = SiftTaxonomy.leaf(id: label) {
            decision = ClassificationDecision(
                labelID: leaf.id, labelTitle: leaf.title, groupID: leaf.groupId,
                groupTitle: leaf.groupTitle, confidence: 0.98,
                systemAction: leaf.systemAction, source: .model
            )
        } else {
            decision = nil
        }
    }
}
