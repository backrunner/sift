import Foundation

public enum ModelOutputContract {
    public static let abstainLabel = "__sift_abstain__"

    public static func isAbstainLabel(_ label: String) -> Bool {
        label == abstainLabel
    }

    public static func abstentionDecision(confidence: Double) -> ClassificationDecision {
        ClassificationDecision(
            labelID: abstainLabel,
            labelTitle: String(localized: "未分类"),
            groupID: "",
            groupTitle: "",
            confidence: confidence,
            systemAction: .none,
            source: .fallback
        )
    }
}

public protocol MessageClassifier: Sendable {
    func classify(sender: String?, body: String) -> ClassificationDecision
}

public enum MessageClassifierInferenceFailure: String, Error, Codable, Hashable, Sendable {
    case predictionFailed
    case invalidOutput
}

/// A classifier that distinguishes a valid abstention from an execution error.
/// MessageFilter uses this signal to fall back immediately only when the model
/// explicitly could not complete inference.
public protocol FailureReportingMessageClassifier: MessageClassifier {
    func classificationResult(
        sender: String?,
        body: String
    ) -> Result<ClassificationDecision, MessageClassifierInferenceFailure>
}

public struct HeuristicClassifier: MessageClassifier {
    public var confidenceThreshold: Double

    public init(confidenceThreshold: Double = 0.65) {
        self.confidenceThreshold = confidenceThreshold
    }

    public func classify(sender: String?, body: String) -> ClassificationDecision {
        let lowercased = body.lowercased()
        if let forced = Self.highPrecisionDecision(for: lowercased) {
            return forced
        }
        if looksLikePersonalConversation(lowercased) {
            return ModelOutputContract.abstentionDecision(confidence: 0.96)
        }
        let matched = bestMatch(in: lowercased)
        let leaf = matched.label

        if matched.confidence < confidenceThreshold {
            return fallbackDecision(confidence: matched.confidence)
        }

        return ClassificationDecision(
            labelID: leaf.id,
            labelTitle: leaf.title,
            groupID: leaf.groupId,
            groupTitle: leaf.groupTitle,
            confidence: matched.confidence,
            systemAction: leaf.systemAction,
            source: .model
        )
    }

    /// High-precision boundaries are applied before a learned classifier can
    /// turn a clearly personal or credential-theft message into a category.
    /// Rules are evaluated before the classifier by MessageFilterEngine, so
    /// this remains subordinate to explicit user allow/block rules.
    public static func highPrecisionDecision(for body: String) -> ClassificationDecision? {
        let lowercased = body.lowercased()
        func forcedDecision(labelID: String, confidence: Double) -> ClassificationDecision? {
            guard let label = SiftTaxonomy.leaf(id: labelID) else {
                return nil
            }
            return ClassificationDecision(
                labelID: label.id,
                labelTitle: label.title,
                groupID: label.groupId,
                groupTitle: label.groupTitle,
                confidence: confidence,
                systemAction: label.systemAction,
                source: .model
            )
        }
        if personalConversationSignal(in: lowercased) {
            return ModelOutputContract.abstentionDecision(confidence: 0.99)
        }

        let travelServiceContextMarkers = [
            "航空", "航班", "机票", "登机", "机场", "铁路", "列车", "动车", "高铁", "车票",
            "客运", "大巴", "轮渡", "渡轮", "邮轮", "游轮", "船票", "登船", "港口", "码头",
            "酒店", "客舱", "接机", "airline", "flight", "boarding", "airport", "rail", "train",
            "coach", "ferry", "cruise", "port", "hotel", "resort", "cabin", "shuttle",
            "航空券", "搭乗", "空港", "鉄道", "列車", "乗車券", "バス", "フェリー", "クルーズ",
            "乗船", "港湾", "ホテル", "客室"
        ]
        let remoteAccessMarkers = [
            "远程控制", "远程操作", "远程协助", "屏幕共享", "共享屏幕", "控制工具", "会议软件",
            "remote-control", "remote control", "remote desktop", "remote-support", "screen sharing", "screen-sharing",
            "share the screen", "screen-control", "meeting app", "遠隔操作", "遠隔支援", "画面共有",
            "画面操作", "会議アプリ"
        ]
        let sensitiveCredentialMarkers = [
            "网银密码", "网银口令", "登录密码", "银行卡密码", "卡片密码", "卡片安全码",
            "卡片安全数字", "短信动态码", "银行应用动态码", "钱包恢复短语", "online-banking password",
            "online banking password", "online account password", "banking login", "account password", "card pin", "card password",
            "card security code", "banking approval code", "wallet recovery phrase", "ネット銀行のパスワード",
            "ネット口座のパスワード", "カード暗証番号", "カードのパスワード", "セキュリティ番号",
            "銀行アプリの承認コード", "ウォレットの復元フレーズ"
        ]
        let credentialRequestMarkers = [
            "要求", "需在", "需要", "填写", "输入", "提供", "回复", "发送", "提交", "上传",
            "asks", "need", "needs", "require", "requires", "enter", "provide", "reply", "send", "submit",
            "upload", "demand", "wants", "求め", "必要", "入力", "返信", "送信", "提出", "アップロード"
        ]
        let credentialSafetyMarkers = [
            "不会索取", "不会要求", "无需提供", "不要提供", "请勿提供", "不要回复", "请勿回复",
            "will never ask", "never request", "does not ask", "do not provide", "do not share", "no need to provide",
            "要求しません", "要求することはありません", "求めることはありません", "送信しないで", "入力不要", "提供不要"
        ]
        let prepaidSecretMarkers = [
            "礼品卡", "购物卡", "充值卡", "兑换码", "卡密", "gift card", "prepaid voucher",
            "store voucher", "redemption number", "redemption code", "プリペイド", "商品券", "引換番号"
        ]
        let prepaidSecretTransmissionMarkers = [
            "发送兑换码", "回传卡号", "发送卡密", "send the redemption", "send redemption",
            "reply with the redemption", "番号を送", "番号を返信"
        ]
        let personalTransferMarkers = [
            "个人账户", "私人账户", "个人收款", "personal account", "private account", "個人口座"
        ]
        let coercedPaymentMarkers = [
            "转账", "保证金", "解锁费", "改签费", "transfer", "deposit", "unlock fee", "rebooking fee",
            "振込", "保証金", "解除手数料", "変更手数料"
        ]
        let hasTravelContext = travelServiceContextMarkers.contains(where: lowercased.contains)
        let credentialSafetyContextMarkers = [
            "安全提醒", "安全提示", "银行提醒", "工作人员", "security reminder", "security notice",
            "bank reminder", "staff", "セキュリティ注意", "銀行からの注意", "職員", "係員"
        ]
        if
            credentialSafetyMarkers.contains(where: lowercased.contains),
            credentialSafetyContextMarkers.contains(where: lowercased.contains),
            sensitiveCredentialMarkers.contains(where: lowercased.contains)
                || remoteAccessMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "transaction.account_security", confidence: 0.99)
        {
            return decision
        }
        let settledBalanceContextMarkers = [
            "保证金余额", "托管余额", "deposit balance", "escrow balance", "保証金残高", "預託残高"
        ]
        let settledBalanceCompletionMarkers = [
            "结算至", "划入", "已转入", "settled into", "moved to", "transferred to", "精算し", "振り替え", "振り込み"
        ]
        let settledBalanceEvidenceMarkers = [
            "尾号", "入账凭证", "银行流水", "account ending", "bank-credit proof", "bank receipt",
            "口座", "入金証明", "銀行明細"
        ]
        if
            settledBalanceContextMarkers.contains(where: lowercased.contains),
            settledBalanceCompletionMarkers.contains(where: lowercased.contains),
            settledBalanceEvidenceMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.bank", confidence: 0.99)
        {
            return decision
        }
        let asksForSensitiveCredential = sensitiveCredentialMarkers.contains(where: lowercased.contains)
            && credentialRequestMarkers.contains(where: lowercased.contains)
            && !credentialSafetyMarkers.contains(where: lowercased.contains)
        let demandsPrepaidSecret = prepaidSecretMarkers.contains(where: lowercased.contains)
            && (
                credentialRequestMarkers.contains(where: lowercased.contains)
                    || prepaidSecretTransmissionMarkers.contains(where: lowercased.contains)
            )
        let demandsPersonalTransfer = personalTransferMarkers.contains(where: lowercased.contains)
            && coercedPaymentMarkers.contains(where: lowercased.contains)
        if
            hasTravelContext,
            remoteAccessMarkers.contains(where: lowercased.contains)
                || asksForSensitiveCredential
                || demandsPrepaidSecret
                || demandsPersonalTransfer,
            let decision = forcedDecision(labelID: "spam", confidence: 0.99)
        {
            return decision
        }

        let trafficPenaltyContextMarkers = [
            "未处理违章", "交通违章", "车辆违章", "traffic violation", "unpaid traffic ticket",
            "traffic penalty", "交通違反", "違反通知"
        ]
        let trafficPenaltyFraudMarkers = [
            "非官方链接", "解锁费", "扣留驾驶证", "unofficial link", "unlock fee", "license suspension",
            "suspend your license", "非公式リンク", "解除料", "免許停止"
        ]
        if
            trafficPenaltyContextMarkers.contains(where: lowercased.contains),
            trafficPenaltyFraudMarkers.filter({ lowercased.contains($0) }).count >= 2,
            let decision = forcedDecision(labelID: "spam", confidence: 0.99)
        {
            return decision
        }

        let completedTravelTicketMarkers = [
            "已改签", "改签完成", "自动重开", "已出票", "已重新出票", "座位调整完成", "座位由", "升级已确认",
            "升级办理成功", "值船手续已完成", "电子票已签发", "登船口改", "boarding pass is ready",
            "was rebooked", "automatically reissued", "ticketed", "seat change is complete", "now uses coach",
            "boarding moved", "upgrade is confirmed", "upgrade succeeded", "check-in is complete", "was moved",
            "変更が完了", "変更されました", "自動で再発行", "発券済み", "座席変更が完了", "号車から", "アップグレードが確定",
            "客室への変更が完了", "乗船手続が完了", "乗船口は"
        ]
        let trustedTravelProcessMarkers = [
            "官方应用", "官方客户端", "官方订单", "官方行程", "无需重新", "无需再次", "票价不变",
            "金额不变", "原付款方式", "不会再次扣款", "继续有效", "仍然有效", "证件原件", "人工柜台", "登机二维码",
            "official app", "official booking", "official trip", "no payment", "fare is unchanged",
            "will not be charged", "remains valid", "original passport", "staffed counter", "boarding qr", "公式アプリ",
            "公式予約", "追加決済", "運賃は", "有効", "原本", "有人窓口", "搭乗qr"
        ]
        if
            hasTravelContext,
            completedTravelTicketMarkers.contains(where: lowercased.contains),
            trustedTravelProcessMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "travel.ticketing", confidence: 0.99)
        {
            return decision
        }

        let connectivityPlanMarkers = [
            "卫星流量", "卫星数据", "无线套餐", "联网套餐", "通信计划", "通信套餐", "satellite allowance",
            "satellite data", "wireless plan", "connectivity plan", "communications plan", "通信量", "無線プラン",
            "通信プラン", "データパック"
        ]
        let connectivityUsageMarkers = [
            "已用", "已使用", "还剩", "剩余", "mb", "gb", "percent used", "remaining", "left",
            "使用済み", "利用済み", "残量", "残って", "%"
        ]
        if
            connectivityPlanMarkers.contains(where: lowercased.contains),
            connectivityUsageMarkers.filter({ lowercased.contains($0) }).count >= 2,
            let decision = forcedDecision(labelID: "carrier.data_reminder", confidence: 0.99)
        {
            return decision
        }

        let fulfilledOrderContextMarkers = ["订单", "order", "注文"]
        let fulfilledOrderStateMarkers = [
            "检验合格", "检验完成", "质检完成", "已包装", "已发出", "交付承运商", "passed inspection",
            "packed", "dispatched", "handed to the carrier", "検品合格", "検品を終え", "梱包", "発送済み", "運送会社へ"
        ]
        let futureOrderBenefitMarkers = [
            "下次订单", "下次购买", "后续购物", "future order", "future purchase", "next order",
            "later purchase", "不影响本次订单状态", "does not change this order's status", "次回注文", "次回購入",
            "今回の注文状態に影響しません"
        ]
        if
            fulfilledOrderContextMarkers.contains(where: lowercased.contains),
            fulfilledOrderStateMarkers.contains(where: lowercased.contains),
            futureOrderBenefitMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "transaction.order", confidence: 0.99)
        {
            return decision
        }

        // Stable domain compositions cover short notifications whose sparse
        // wording can otherwise fall below the learned-model confidence gate.
        // Each rule requires both a domain entity and a state/event marker.
        let civicDrillContextMarkers = [
            "应急部门", "应急管理", "emergency officials", "emergency services", "emergency office",
            "防災当局", "防災機関", "保健当局", "自治体", "卫生部门", "health authority"
        ]
        let civicDrillEventMarkers = [
            "演练", "警报", "避难", "drill", "alarm", "warning", "shelter", "refuge", "evacuat", "walk",
            "提醒", "remind", "防災", "訓練", "避難", "案内"
        ]
        if
            civicDrillContextMarkers.contains(where: lowercased.contains),
            civicDrillEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "government.reminder", confidence: 0.99)
        {
            return decision
        }

        let securityKeyContextMarkers = [
            "security key", "passkey", "安全密钥", "通行密钥", "セキュリティキー", "パスキー"
        ]
        let securityKeyStateMarkers = [
            "registered", "已注册", "已登记", "authorized", "仍然有效", "remains authorized",
            "登録", "認証済み", "有効"
        ]
        if
            securityKeyContextMarkers.contains(where: lowercased.contains),
            securityKeyStateMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "transaction.account_security", confidence: 0.99)
        {
            return decision
        }

        let disabilityBenefitContextMarkers = [
            "残障生活津贴", "残障津贴", "disability allowance", "disability benefit", "障害生活手当", "障害給付"
        ]
        let disabilityBenefitStateMarkers = [
            "复核通过", "年度复核", "annual review", "passed", "adjusted benefit", "資格確認", "年次確認"
        ]
        if
            disabilityBenefitContextMarkers.contains(where: lowercased.contains),
            disabilityBenefitStateMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "government.social_security", confidence: 0.99)
        {
            return decision
        }

        let procurementApprovalContextMarkers = [
            "采购合规", "供应商核验", "采购申请", "procurement compliance", "vendor verification", "purchase request",
            "purchasing request", "購買確認", "仕入先確認", "購買申請"
        ]
        let procurementApprovalStateMarkers = [
            "等待", "批准", "审批", "财务复核", "成本中心", "approval", "approve", "awaits", "finance review",
            "cost center", "承認", "承認待ち", "支払条件", "財務確認", "原価部門"
        ]
        if
            procurementApprovalContextMarkers.contains(where: lowercased.contains),
            procurementApprovalStateMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "work.approval", confidence: 0.99)
        {
            return decision
        }

        let retentionExceptionContextMarkers = [
            "数据保留例外", "数据留存例外", "data-retention exception", "data retention exception",
            "データ保持の例外", "保存期間の例外"
        ]
        let retentionReviewMarkers = [
            "安全审查通过", "通过安全审查", "cleared security review", "passed security review",
            "セキュリティ審査済み", "安全審査を通過"
        ]
        let retentionApprovalMarkers = [
            "等待合规批准", "等待合规审批", "awaits compliance approval", "pending compliance approval",
            "コンプライアンス承認待ち", "法令遵守部門の承認待ち"
        ]
        if
            retentionExceptionContextMarkers.contains(where: lowercased.contains),
            retentionReviewMarkers.contains(where: lowercased.contains),
            retentionApprovalMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "work.approval", confidence: 0.99)
        {
            return decision
        }

        let reviewedDataAccessMarkers = [
            "数据导出", "资料导出", "导出权限", "data export", "record export", "export access",
            "データ書き出し", "記録の書き出し", "書き出し権限"
        ]
        let reviewedDataPrivacyMarkers = [
            "隐私审查", "隐私复核", "privacy review", "個人情報審査", "プライバシー審査"
        ]
        let reviewedDataApprovalMarkers = [
            "仍需", "等待", "批准", "needs", "awaits", "pending", "承認が必要", "承認待ち"
        ]
        if
            reviewedDataAccessMarkers.contains(where: lowercased.contains),
            reviewedDataPrivacyMarkers.contains(where: lowercased.contains),
            reviewedDataApprovalMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "work.approval", confidence: 0.99)
        {
            return decision
        }

        let flexibleScheduleContextMarkers = [
            "flexible schedule", "flexible-schedule", "compressed workweek", "compressed-workweek",
            "弹性排班", "弹性工时", "压缩工作周", "フレックス勤務", "時差勤務", "週4日勤務"
        ]
        let flexibleScheduleStateMarkers = [
            "approved", "request", "clock-in", "attendance", "申请已通过", "考勤", "承認", "勤怠"
        ]
        if
            flexibleScheduleContextMarkers.contains(where: lowercased.contains),
            flexibleScheduleStateMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "work.attendance", confidence: 0.99)
        {
            return decision
        }

        let shiftRosterContextMarkers = [
            "排班", "班次", "roster", "shift schedule", "勤務表", "シフト"
        ]
        let shiftRosterChangeMarkers = [
            "调整", "改由", "changed", "cover", "reassigned", "変更", "担当", "夜勤"
        ]
        let attendanceContextMarkers = ["考勤", "attendance", "勤怠"]
        if
            shiftRosterContextMarkers.contains(where: lowercased.contains),
            shiftRosterChangeMarkers.contains(where: lowercased.contains),
            attendanceContextMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "work.attendance", confidence: 0.99)
        {
            return decision
        }

        let missingClockContextMarkers = [
            "门禁刷卡", "打卡记录", "entry swipe", "clock record", "入館打刻", "出退勤打刻"
        ]
        let missingClockProblemMarkers = ["缺失", "漏打", "missing", "欠落", "記録なし"]
        let missingClockCorrectionMarkers = [
            "补签", "更正申请", "correction", "filed", "修正申請", "訂正申請"
        ]
        if
            missingClockContextMarkers.contains(where: lowercased.contains),
            missingClockProblemMarkers.contains(where: lowercased.contains),
            missingClockCorrectionMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "work.attendance", confidence: 0.99)
        {
            return decision
        }

        let refrigeratedPickupContextMarkers = [
            "冷藏疫苗", "疫苗包", "refrigerated vaccine", "vaccine parcel", "冷蔵ワクチン", "ワクチン包"
        ]
        let refrigeratedPickupEventMarkers = [
            "领取", "领取码", "取件码", "pickup pin", "pickup code", "取走", "受取", "引取"
        ]
        if
            refrigeratedPickupContextMarkers.contains(where: lowercased.contains),
            refrigeratedPickupEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "life.pickup_code", confidence: 0.99)
        {
            return decision
        }

        let utilityCampaignContextMarkers = [
            "供水服务", "用水服务", "家庭地热", "home-water service", "water service", "home geothermal",
            "home-geothermal", "家庭用水", "水道サービス", "家庭用地熱"
        ]
        let utilityCampaignOfferMarkers = [
            "活动", "优惠", "免费", "campaign", "offer", "free", "企画", "無料"
        ]
        if
            utilityCampaignContextMarkers.contains(where: lowercased.contains),
            utilityCampaignOfferMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "promotion", confidence: 0.99)
        {
            return decision
        }

        let refundProblemMarkers = [
            "退款失败", "退款卡住", "退款异常", "refund failed", "refund is stuck",
            "refund problem", "返金失敗", "返金処理の停止", "返金できない"
        ]
        let credentialTransferMarkers = [
            "把验证码发", "转发验证码", "验证码转发", "send the verification code",
            "forward the verification code", "forward the code", "認証コードを転送",
            "認証番号を送", "コードを転送", "認証コードを送"
        ]
        let impersonationMarkers = [
            "冒充", "假冒", "所谓", "自称", "fake delivery", "fake courier", "impersonat", "supposed",
            "posing as", "偽の配送", "偽の業者", "配送業者を装", "窓口を装", "装い", "名乗"
        ]
        let sensitiveRequestMarkers = [
            "重新派送费", "派送费", "redelivery fee", "card security code", "security code",
            "银行卡安全码", "礼品卡", "购物卡", "gift card", "卡密", "短信验证码", "one-time code",
            "advance fee", "registration fee", "review fee", "file-review", "审核费", "登记费",
            "先支付", "先缴", "再配達料", "セキュリティコード", "ワンタイムコード", "申請料", "先払い"
        ]
        let requestMarkers = [
            "要求", "索取", "填写", "输入", "支付", "demand", "request", "asks", "send", "enter",
            "求め", "支払", "入力", "送る"
        ]
        if
            impersonationMarkers.contains(where: lowercased.contains),
            sensitiveRequestMarkers.contains(where: lowercased.contains),
            requestMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "spam", confidence: 0.99)
        {
            return decision
        }
        let failedDeliveryMarkers = [
            "派送失败", "投递失败", "包裹异常", "delivery failed", "parcel is held", "配送失敗", "荷物を保留"
        ]
        let redeliveryPaymentMarkers = [
            "重新投递费", "重新派送费", "redelivery fee", "再配達料"
        ]
        if
            failedDeliveryMarkers.contains(where: lowercased.contains),
            redeliveryPaymentMarkers.contains(where: lowercased.contains),
            requestMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "spam", confidence: 0.99)
        {
            return decision
        }
        let detainedParcelMarkers = [
            "包裹被海关扣留", "包裹被扣留", "快件被扣留", "parcel held by customs", "parcel is detained",
            "荷物が税関で保留", "荷物を差し止め"
        ]
        let parcelReleaseFraudMarkers = [
            "陌生短链", "陌生页面", "非官方链接", "解锁费", "填写银行卡", "银行卡信息",
            "unfamiliar link", "unofficial page", "unlock fee", "enter card", "banking details",
            "不審なリンク", "非公式ページ", "解除料", "カード情報"
        ]
        if
            detainedParcelMarkers.contains(where: lowercased.contains),
            parcelReleaseFraudMarkers.filter({ lowercased.contains($0) }).count >= 2,
            let decision = forcedDecision(labelID: "spam", confidence: 0.99)
        {
            return decision
        }
        if
            refundProblemMarkers.contains(where: lowercased.contains),
            credentialTransferMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "spam", confidence: 0.99)
        {
            return decision
        }

        let refundClaimMarkers = [
            "退款待领取", "领取退款", "退款待认领", "认领退款",
            "refund waiting to be claimed", "refund is ready to claim", "claim your refund",
            "返金の受取待ち", "返金を受け取", "返金をお受け取り"
        ]
        let externalLinkMarkers = ["https://", "http://", "www."]
        let bankCredentialMarkers = [
            "填写银行卡", "输入银行卡", "提供银行卡", "银行卡信息", "银行卡密码", "银行卡安全码",
            "enter your card", "provide your card", "card information", "card details", "banking details",
            "カード情報を入力", "カード番号を入力", "銀行口座情報を入力", "暗証番号を入力"
        ]
        if
            refundClaimMarkers.contains(where: lowercased.contains),
            externalLinkMarkers.contains(where: lowercased.contains),
            bankCredentialMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "spam", confidence: 0.99)
        {
            return decision
        }

        // Completed merchant reversals are normal financial events. Keep this
        // ahead of the broad account-security rule because "reversal" and
        // "account" can otherwise look like a revoked credential state.
        let completedRefundMarkers = [
            "商户撤销", "退回原支付账户", "merchant reversal", "returns to the original payment",
            "加盟店の取消", "元の支払口座へ戻"
        ]
        if
            completedRefundMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.refund", confidence: 0.99)
        {
            return decision
        }

        let canceledDepositMarkers = [
            "押金", "保证金", "deposit", "rental cancellation", "保証金", "レンタル"
        ]
        let canceledDepositReturnMarkers = [
            "已取消", "取消完成", "原支付", "退回", "cancellation is complete", "return through the original",
            "original payment", "払い戻し", "取消が完了", "元の支払"
        ]
        if
            canceledDepositMarkers.contains(where: lowercased.contains),
            canceledDepositReturnMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.refund", confidence: 0.99)
        {
            return decision
        }

        let cardStatementMarkers = [
            "信用卡账单", "循环卡账单", "credit card statement", "credit-card statement", "revolving-card statement",
            "カード請求額", "クレジットカードの請求", "カード利用代金", "リボカードの請求"
        ]
        let cardAccountMarkers = [
            "信用卡", "循环卡", "商务卡", "企业卡", "card statement", "credit card", "revolving card",
            "revolving-card", "business card", "business-card", "corporate card", "fleet card",
            "クレジットカード", "リボカード", "法人カード", "業務カード", "カード"
        ]
        let cardBillingMarkers = [
            "账单", "月结单", "应还", "statement balance", "amount due", "請求", "請求額", "今月の請求"
        ]
        let cardPaymentDueMarkers = [
            "最低还款", "最低支付", "应还", "到期", "minimum payment", "minimum due", "amount due", "due by",
            "最低支払額", "支払期限", "支払期日", "期限"
        ]
        if
            (
                cardStatementMarkers.contains(where: lowercased.contains)
                    || (
                        cardAccountMarkers.contains(where: lowercased.contains)
                            && cardBillingMarkers.contains(where: lowercased.contains)
                    )
            ),
            cardPaymentDueMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.credit_card", confidence: 0.99)
        {
            return decision
        }

        let hasCardPurchaseInstrument = lowercased.contains("信用卡")
            || lowercased.contains("card ending")
            || lowercased.contains("credit card")
            || lowercased.contains("のカード")
            || (lowercased.contains("尾号") && lowercased.contains("卡"))
            || (lowercased.contains("末尾") && lowercased.contains("カード"))
        let cardPurchaseEventMarkers = [
            "消费", "刷卡", "交易已确认", "purchase", "charge", "利用", "決済"
        ]
        if
            hasCardPurchaseInstrument,
            cardPurchaseEventMarkers.contains(where: lowercased.contains),
            !cardBillingMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.consumption", confidence: 0.98)
        {
            return decision
        }

        // Toll notices are often phrased as a road/traffic event, but a card
        // payment is a finance.consumption transaction. Require both sides of
        // that boundary so ordinary road advisories remain travel/government.
        let tollPaymentContextMarkers = [
            "高速收费站", "高速通行", "通行支付", "toll road", "toll-road", "tollway",
            "bay expressway", "高速料金", "高速道路料金", "料金所"
        ]
        let tollPaymentEventMarkers = [
            "卡", "信用卡", "card ending", "purchase", "posted", "paid", "payment",
            "交易已入账", "完成支付", "支払い", "利用明細", "決済"
        ]
        if
            tollPaymentContextMarkers.contains(where: lowercased.contains),
            tollPaymentEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.consumption", confidence: 0.99)
        {
            return decision
        }

        let earlyIncomeMarkers = ["工资", "薪资", "salary", "payroll", "給与", "賞与"]
        let earlyIncomeCompletionMarkers = ["入账", "存入", "credited", "deposited", "入金"]
        if
            earlyIncomeMarkers.contains(where: lowercased.contains),
            earlyIncomeCompletionMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.income", confidence: 0.98)
        {
            return decision
        }

        let scheduledTransferContextMarkers = [
            "年金转账", "年金振込", "跨境汇款", "海外振込", "scheduled transfer", "pension transfer", "overseas transfer"
        ]
        let scheduledTransferReceiptMarkers = [
            "账户尾号", "末尾", "account ending", "口座", "银行回执", "bank receipt", "银行记录", "bank activity",
            "振込", "送金", "transfer receipt", "銀行記録"
        ]
        if
            scheduledTransferContextMarkers.contains(where: lowercased.contains),
            scheduledTransferReceiptMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.bank", confidence: 0.99)
        {
            return decision
        }

        let bankAccountMarkers = [
            "储蓄账户尾号", "账户尾号", "末尾", "savings account ending", "account ending", "普通預金口座末尾", "口座末尾"
        ]
        let bankDebitMarkers = [
            "支出", "扣款", "余额", "debited", "balance", "引き落と", "口座から"
        ]
        if
            bankAccountMarkers.contains(where: lowercased.contains),
            bankDebitMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.bank", confidence: 0.98)
        {
            return decision
        }

        let carrierInvoiceContextMarkers = [
            "通信服务", "家庭宽带", "宽带", "通信账户", "通信费", "通信账单", "物联网卡", "副卡", "运营商",
            "mobile service", "broadband", "telecom account", "telecom charge", "companion sim", "additional sim",
            "通信サービス", "通信料", "光回線", "通信口座", "追加sim", "副回線"
        ]
        let carrierInvoiceMarkers = [
            "月结单", "账单", "发票", "服务发票", "自动缴费", "自动扣款", "statement", "bill", "service invoice",
            "autopay", "will be debited", "billing date", "月額請求", "利用請求", "請求日", "自動引き落とし",
            "まとめて引き落と", "口座振替"
        ]
        if
            carrierInvoiceContextMarkers.contains(where: lowercased.contains),
            carrierInvoiceMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "carrier.billing", confidence: 0.98)
        {
            return decision
        }

        let investmentFraudMarkers = [
            "荐股", "内部消息", "股票群", "stock group", "stock-tip", "investment mentor",
            "private stock", "株情報", "投資助言", "銘柄情報"
        ]
        let investmentPaymentMarkers = [
            "保证", "涨停", "入群费", "私人账户", "个人账户", "guarantee", "entry fee",
            "personal account", "membership payment", "上昇を保証", "参加費", "個人口座", "会員料"
        ]
        if
            investmentFraudMarkers.contains(where: lowercased.contains),
            investmentPaymentMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "spam", confidence: 0.99)
        {
            return decision
        }

        let unfamiliarPageMarkers = [
            "陌生页面", "不熟悉页面", "非官方页面", "unfamiliar page", "unknown page", "unofficial page",
            "不審なページ", "非公式ページ"
        ]
        let credentialBundleMarkers = [
            "密码", "身份证", "身份照片", "验证码", "password", "identity number", "identity photo", "sms code",
            "パスワード", "身分証", "身分証写真", "smsコード"
        ]
        if
            unfamiliarPageMarkers.contains(where: lowercased.contains),
            credentialBundleMarkers.filter({ lowercased.contains($0) }).count >= 2,
            let decision = forcedDecision(labelID: "spam", confidence: 0.99)
        {
            return decision
        }

        let walletRecoveryMarkers = [
            "钱包助记词", "钱包恢复短语", "恢复短语", "wallet recovery phrase", "wallet seed phrase",
            "recovery phrase", "seed words", "復元語", "リカバリーフレーズ", "シードフレーズ"
        ]
        let cloudStorageMarkers = [
            "云盘", "云存储", "云空间", "cloud storage", "cloud drive", "cloud-storage",
            "云相册", "cloud album", "cloud photo", "クラウド容量", "クラウドストレージ", "クラウドアルバム"
        ]
        let recoveryRequestMarkers = [
            "要求", "输入", "填写", "保留文件", "asks", "request", "enter", "provide", "保存",
            "要求しています", "求め", "入力"
        ]
        if
            cloudStorageMarkers.contains(where: lowercased.contains),
            walletRecoveryMarkers.contains(where: lowercased.contains),
            recoveryRequestMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "spam", confidence: 0.99)
        {
            return decision
        }

        let supplierReviewMarkers = [
            "供应商风险评估", "供应商风险审查", "supplier risk review", "vendor risk review",
            "取引先リスク審査", "サプライヤーリスク審査"
        ]
        let supplierApprovalMarkers = [
            "法务核对", "等待业务负责人批准", "批准付款周期", "cleared legal", "awaits the business owner",
            "approval of payment terms", "法務確認済み", "支払条件承認待ち", "承認待ち"
        ]
        if
            supplierReviewMarkers.contains(where: lowercased.contains),
            supplierApprovalMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "work.approval", confidence: 0.99)
        {
            return decision
        }

        let orderMarkers = ["订单", "order", "注文"]
        let orderPaidMarkers = ["已付款", "支付完成", "已完成付款", "is paid", "is complete", "payment is complete", "支払い済み", "決済済み"]
        let orderFulfillmentMarkers = [
            "仓库", "工厂", "发货", "发运", "打包", "warehouse", "workshop", "factory", "pack", "ship",
            "倉庫", "工房", "工場", "梱包", "発送"
        ]
        if
            orderMarkers.contains(where: lowercased.contains),
            orderPaidMarkers.contains(where: lowercased.contains),
            orderFulfillmentMarkers.contains(where: lowercased.contains),
            let label = SiftTaxonomy.leaf(id: "transaction.order")
        {
            return ClassificationDecision(
                labelID: label.id, labelTitle: label.title, groupID: label.groupId,
                groupTitle: label.groupTitle, confidence: 0.98,
                systemAction: label.systemAction, source: .model
            )
        }

        let customOrderMarkers = [
            "定制", "custom", "特注", "オーダーメイド"
        ]
        let customOrderCompletionMarkers = [
            "尾款", "final payment", "balance is paid", "残金", "残金決済", "workshop", "车间", "工房"
        ]
        if
            customOrderMarkers.contains(where: lowercased.contains),
            customOrderCompletionMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "transaction.order", confidence: 0.98)
        {
            return decision
        }

        let membershipMarkers = [
            "会员", "会员等级", "会员权益", "membership", "member tier", "member benefits",
            "会員", "会員ランク", "会員特典"
        ]
        let membershipCompletionMarkers = [
            "升级申请已通过", "新等级", "下个账期生效", "权益变更已确认", "approved", "confirmed",
            "new tier", "begin next billing cycle", "takes effect", "next statement cycle",
            "续期", "续费成功", "有效期", "renewed", "new term", "valid through", "extended",
            "ランク変更が承認", "次回の請求期間から有効", "新しい特典", "適用されます",
            "会員資格を更新", "会員を更新", "有効期限", "延長しました"
        ]
        if
            membershipMarkers.contains(where: lowercased.contains),
            membershipCompletionMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "transaction.member", confidence: 0.98)
        {
            return decision
        }

        let softwareUpdateContextMarkers = [
            "桌面客户端", "桌面浏览器", "应用更新", "desktop client", "desktop browser", "desktop app",
            "application update", "デスクトップアプリ", "デスクトップブラウザ", "アプリ更新"
        ]
        let softwareUpdateCompletionMarkers = [
            "更新完成", "已安装", "finished", "is complete", "installed successfully", "更新が完了", "インストールが完了"
        ]
        if
            softwareUpdateContextMarkers.contains(where: lowercased.contains),
            softwareUpdateCompletionMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "transaction.message", confidence: 0.98)
        {
            return decision
        }

        let archiveExportContextMarkers = [
            "消息归档", "邮件归档", "数据副本", "活动归档", "message archive", "mail archive",
            "data copy", "activity archive", "メッセージ保管", "メール保管", "データコピー", "操作履歴"
        ]
        let archiveExportCompletionMarkers = [
            "导出完成", "已经生成", "下载", "export finished", "is ready", "download",
            "書き出しが完了", "作成が完了", "ダウンロード", "取得できます"
        ]
        if
            archiveExportContextMarkers.contains(where: lowercased.contains),
            archiveExportCompletionMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "transaction.message", confidence: 0.98)
        {
            return decision
        }

        let accountSecurityStatusMarkers = [
            "移除设备", "删除设备", "设备已移除", "不能再访问", "不再访问个人资料", "安全验证已通过",
            "撤销", "授权", "注销", "removed", "revoked", "ended access", "sign out", "browser token",
            "访问令牌", "access token", "no longer access", "two-step verification is now on", "device was removed",
            "認証トークン", "無効にし", "権限を終了", "ログアウト",
            "端末を削除", "アクセスできません", "端末からプロフィールへアクセスできません",
            "二段階認証が有効", "ログイン"
        ]
        let accountSecurityContextMarkers = [
            "账户", "账号", "个人资料", "account", "profile", "device", "设备", "端末", "アカウント",
            "security center", "browser", "tablet", "token", "session", "セキュリティセンター", "タブレット"
        ]
        if
            accountSecurityStatusMarkers.contains(where: lowercased.contains),
            accountSecurityContextMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "transaction.account_security", confidence: 0.98)
        {
            return decision
        }

        let passkeySecurityMarkers = [
            "通行密钥", "passkey", "security key", "パスキー", "セキュリティキー"
        ]
        let passkeyStateMarkers = [
            "备份已刷新", "旧恢复代码", "backup was refreshed", "recovery codes remain valid",
            "バックアップを更新", "復旧コードは引き続き有効"
        ]
        if
            passkeySecurityMarkers.contains(where: lowercased.contains),
            passkeyStateMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "transaction.account_security", confidence: 0.99)
        {
            return decision
        }

        let mediaPromotionMarkers = [
            "家庭影音", "家庭视频", "home-video", "home video", "家庭向けビデオ", "ホームビデオ"
        ]
        let mediaPromotionEventMarkers = [
            "活动", "促销", "订阅", "首月", "减免", "获赠", "promotion", "subscription", "first month",
            "discount", "complimentary", "企画", "初月", "割引", "特典"
        ]
        if
            mediaPromotionMarkers.contains(where: lowercased.contains),
            mediaPromotionEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "promotion", confidence: 0.98)
        {
            return decision
        }

        let operationalResourceMarkers = [
            "生产日志", "日志索引", "接口证书", "签名证书", "消息队列", "production log", "production database",
            "production signing certificate", "signing certificate", "log index", "certificate", "api certificate", "message queue", "本番日志", "本番データベース",
            "备份仓库", "备份数据库", "加密主密钥", "backup vault", "backup database", "encryption master key",
            "ログ索引", "証明書", "api証明書", "メッセージキュー", "バックアップ保管庫", "バックアップdb", "暗号鍵"
        ]
        let operationalRiskMarkers = [
            "配额", "容量不足", "停止写入", "过期", "到期", "quota", "retention", "capacity", "stop accepting writes", "stop accepting order events",
            "expire", "expires", "容量", "書き込み", "期限", "失効"
        ]
        if
            operationalResourceMarkers.contains(where: lowercased.contains),
            operationalRiskMarkers.contains(where: lowercased.contains),
            let label = SiftTaxonomy.leaf(id: "work.alert")
        {
            return ClassificationDecision(
                labelID: label.id, labelTitle: label.title, groupID: label.groupId,
                groupTitle: label.groupTitle, confidence: 0.98,
                systemAction: label.systemAction, source: .model
            )
        }
        let storageAlertResourceMarkers = [
            "对象存储", "对象存储写入", "artifact registry", "object-storage", "object storage",
            "成果物レジストリ", "オブジェクトストレージ"
        ]
        let storageAlertRiskMarkers = [
            "延迟", "备份任务", "latency", "backups", "writes", "空き容量", "遅延", "バックアップ"
        ]
        if
            storageAlertResourceMarkers.contains(where: lowercased.contains),
            storageAlertRiskMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "work.alert", confidence: 0.98)
        {
            return decision
        }

        // A voicemail transcription maintenance notice is a carrier service
        // event, not a reminder about an individual missed call. Keep this
        // ahead of the generic voicemail rule below.
        let voicemailTranscriptionContextMarkers = [
            "语音信箱转写", "语音留言转写", "voicemail transcription", "voicemail-to-text",
            "留守番電話文字化", "留守番電話の文字起こし", "文字化基盤"
        ]
        let voicemailTranscriptionEventMarkers = [
            "平台", "系统", "升级", "维护", "延迟", "platform", "service system",
            "upgrade", "maintenance", "delayed", "基盤", "更新", "遅れ"
        ]
        if
            voicemailTranscriptionContextMarkers.contains(where: lowercased.contains),
            voicemailTranscriptionEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "carrier.service", confidence: 0.99)
        {
            return decision
        }

        let missedCallMarkers = [
            "未接来电", "未接电话", "语音信箱", "missed call", "voicemail", "called while your line was busy",
            "不在着信", "留守番電話", "通話中に"
        ]
        let callRecordMarkers = [
            "来自", "来电号码", "没有语音", "from", "left no", "new message", "callback reminder",
            "から", "メッセージ", "折り返し"
        ]
        if
            missedCallMarkers.contains(where: lowercased.contains),
            callRecordMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "carrier.call_reminder", confidence: 0.99)
        {
            return decision
        }

        let pickupLockerMarkers = [
            "冷柜", "冷冻柜", "冷藏柜", "refrigerator", "refrigerated", "freezer", "locker", "cold cabinet",
            "cryogenic cabinet", "冷凍庫", "冷蔵庫", "冷蔵ロッカー"
        ]
        let pickupCodeMarkers = [
            "提取码", "提取密码", "取货码", "领取口令", "pickup", "pin", "access pin", "access code",
            "collection code", "using code", "受取番号", "引取コード", "引取番号", "引取编号", "受領番号"
        ]
        if
            pickupLockerMarkers.contains(where: lowercased.contains),
            pickupCodeMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "life.pickup_code", confidence: 0.99)
        {
            return decision
        }

        let carrierRewardMarkers = [
            "运营商积分", "通信积分", "话费积分", "电信积分", "移动积分", "联通积分",
            "carrier points", "carrier rewards", "mobile rewards",
            "キャリアポイント", "通信ポイント"
        ]
        let carrierRewardOfferMarkers = [
            "兑换", "流量包", "入口已开放", "exchange", "data pass", "redemption", "redeem",
            "交換", "データパック", "受付"
        ]
        if
            carrierRewardMarkers.contains(where: lowercased.contains),
            carrierRewardOfferMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "carrier.promotion", confidence: 0.98)
        {
            return decision
        }

        let sharedPlanMarkers = [
            "共享家庭套餐", "家庭共享套餐", "shared family plan", "shared mobile plan", "家族共有プラン"
        ]
        let sharedPlanBenefitMarkers = [
            "增加线路", "额外线路", "周末流量", "extra lines", "weekend data", "bonus data",
            "追加回線", "週末データ", "特典データ"
        ]
        if
            sharedPlanMarkers.contains(where: lowercased.contains),
            sharedPlanBenefitMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "carrier.promotion", confidence: 0.98)
        {
            return decision
        }

        let retailPromotionContextMarkers = [
            "药房", "药店", "pharmacy", "drugstore", "保险", "insurance", "insurer",
            "薬局", "ドラッグストア", "保険"
        ]
        let retailPromotionOfferMarkers = [
            "优惠", "折扣", "促销", "活动", "领券", "满减", "新品", "试算", "报价",
            "discount", "% off", "sale", "deal", "offer", "coupon", "voucher", "new arrivals", "quote",
            "割引", "セール", "キャンペーン", "クーポン", "特典", "見積"
        ]
        if
            retailPromotionContextMarkers.contains(where: lowercased.contains),
            retailPromotionOfferMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "promotion", confidence: 0.99)
        {
            return decision
        }

        let experiencePromotionContextMarkers = [
            "博物馆", "档案馆", "体验课", "修复体验", "museum", "archive workshop", "restoration workshop",
            "experience class", "博物館", "公文書館", "修復体験", "体験講座"
        ]
        let experiencePromotionOfferMarkers = [
            "早鸟", "双人", "减免", "赠", "early booking", "pairs", "waive", "free", "bonus",
            "早期", "2名", "二人", "無料", "割引", "特典"
        ]
        if
            experiencePromotionContextMarkers.contains(where: lowercased.contains),
            experiencePromotionOfferMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "promotion", confidence: 0.99)
        {
            return decision
        }

        let stockMarkers = ["股票", "证券", "股", "shares", "stock", "brokerage", "株", "証券"]
        let stockEventMarkers = [
            "限价", "成交", "中签", "现金红利", "股息", "派息", "limit order", "filled", "share allocation",
            "cash dividend", "dividend", "brokerage funds", "約定", "当選", "現金配当", "配当金"
        ]
        if
            stockMarkers.contains(where: lowercased.contains),
            stockEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.stock", confidence: 0.98)
        {
            return decision
        }

        let dividendContextMarkers = [
            "证券账户", "证券资金", "brokerage", "brokerage funds", "cash dividend", "dividend", "配当金", "証券口座"
        ]
        if
            dividendContextMarkers.contains(where: lowercased.contains),
            stockEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.stock", confidence: 0.98)
        {
            return decision
        }

        let wealthMarkers = [
            "理财产品", "理财结算", "组合调仓", "组合赎回", "稳健组合", "investment product", "managed product",
            "balanced investment product", "portfolio rebalance", "portfolio redemption", "運用商品", "ポートフォリオ",
            "運用ポートフォリオ"
        ]
        let wealthEventMarkers = [
            "赎回", "到期", "本金", "风险等级", "预约", "结算款", "redemption", "matured", "principal", "risk level",
            "reservations", "settled", "settlement proceeds", "解約", "満期", "元本", "リスク区分", "予約", "決済"
        ]
        if
            wealthMarkers.contains(where: lowercased.contains),
            wealthEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.wealth", confidence: 0.97)
        {
            return decision
        }

        let taxAuthorityMarkers = [
            "税务局", "税务机关", "电子税务", "纳税人", "tax office", "tax authority", "taxpayer",
            "税務署", "税務アカウント", "納税"
        ]
        let taxEventMarkers = [
            "申报", "受理", "回执", "缴款", "完税", "filing", "return was accepted", "receipt",
            "tax payment", "申告", "受理", "受付", "納付", "納税証明"
        ]
        if
            taxAuthorityMarkers.contains(where: lowercased.contains),
            taxEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "government.tax", confidence: 0.98)
        {
            return decision
        }

        let socialSecurityMarkers = [
            "社保", "养老保险", "医疗保险", "社会保险", "social security", "social-insurance", "pension",
            "social-insurance account", "unemployment benefit", "unemployment-benefit", "社会保険", "年金", "医療保険",
            "失业补助", "失业保险", "遗属津贴", "遗属待遇", "survivor benefit", "survivor-benefit",
            "bereavement benefit", "失業給付", "遺族給付", "遺族年金"
        ]
        let socialSecurityEventMarkers = [
            "缴费记录", "权益记录", "资格", "待遇", "contribution", "benefit record", "eligibility",
            "eligibility review", "review is complete", "recheck", "passed", "payment record", "next payment date",
            "payment schedule", "update", "statement", "保険料", "給付", "受給資格", "資格確認", "再審査",
            "通過", "支給日", "更新", "記録"
        ]
        if
            socialSecurityMarkers.contains(where: lowercased.contains),
            socialSecurityEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "government.social_security", confidence: 0.98)
        {
            return decision
        }

        let familyCourtContextMarkers = [
            "家事法院", "遗产清册", "遗嘱认证法庭", "probate court", "probate", "estate inventory", "estate filing",
            "家庭裁判所", "遺産目録", "遺言検認裁判所", "資産目録"
        ]
        let familyCourtProcessMarkers = [
            "排期", "询问", "审理", "received", "hearing", "serve", "scheduling",
            "日程", "審理", "受領", "送達"
        ]
        if
            familyCourtContextMarkers.contains(where: lowercased.contains),
            familyCourtProcessMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "government.court", confidence: 0.99)
        {
            return decision
        }

        let takeawayMarkers = [
            "外卖", "餐食", "餐馆", "晚餐", "午餐订单", "meal", "dinner order", "lunch order", "restaurant",
            "食事", "昼食", "夕食", "レストラン"
        ]
        let takeawayEventMarkers = [
            "骑手", "取餐", "接单", "烹饪", "备餐", "送达", "rider", "courier", "preparing", "cooking", "pickup",
            "delivery address", "配達員", "受取", "調理", "届け先"
        ]
        if
            takeawayMarkers.contains(where: lowercased.contains),
            takeawayEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "life.takeaway", confidence: 0.98)
        {
            return decision
        }

        let parcelDeliveryContextMarkers = [
            "快递员", "快件", "包裹", "courier", "parcel", "delivery depot", "配達員", "荷物", "営業所"
        ]
        let parcelDeliveryEventMarkers = [
            "网点出发", "派送", "送达", "重新派送", "left the depot", "deliver", "rescheduled",
            "営業所を出発", "配達", "再配達"
        ]
        if
            parcelDeliveryContextMarkers.contains(where: lowercased.contains),
            parcelDeliveryEventMarkers.contains(where: lowercased.contains),
            !takeawayMarkers.contains(where: lowercased.contains),
            ![
                "支付", "银行卡", "卡号", "陌生", "解锁费", "payment", "card number", "banking details",
                "unfamiliar", "unlock fee", "支払い", "カード番号", "不審"
            ].contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "life.express", confidence: 0.98)
        {
            return decision
        }

        let logisticsMarkers = [
            "运单", "货物", "货件", "货运", "shipment", "consignment", "cargo", "customs clearance", "bonded depot",
            "貨物", "輸送", "通関", "保税倉庫"
        ]
        let logisticsEventMarkers = [
            "干线", "转运中心", "分拨", "监管仓", "line-haul", "transfer hub", "distribution warehouse",
            "customs", "海关", "保税仓", "幹線", "中継拠点", "仕分け", "通関"
        ]
        if
            logisticsMarkers.contains(where: lowercased.contains),
            logisticsEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "life.logistics", confidence: 0.98)
        {
            return decision
        }

        let medicalLogisticsContextMarkers = [
            "病理切片", "病理标本", "病理標本", "组织样本", "血液样本", "pathology slide", "pathology specimen",
            "tissue sample", "blood sample", "病理スライド", "組織試料", "血液試料"
        ]
        let medicalLogisticsEventMarkers = [
            "转交", "转运", "运往", "运输", "冷链", "低温", "transferred", "transfer", "transport",
            "cold-chain", "refrigerated", "引き渡", "搬送", "輸送", "低温"
        ]
        if
            medicalLogisticsContextMarkers.contains(where: lowercased.contains),
            medicalLogisticsEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "life.logistics", confidence: 0.99)
        {
            return decision
        }

        let announcementMarkers = [
            "公司公告", "公司通知", "行政公告", "园区通告", "company announcement", "company notice",
            "administration notice", "campus administration notice", "office campus notice", "社内告知", "社内通知", "総務からのお知らせ",
            "园区行政通知", "办公园区通知", "施設総務", "オフィス施設通知"
        ]
        let announcementEventMarkers = [
            "演练", "办公楼", "办公区", "停车入口", "访客", "员工", "fire drill", "office", "staff", "visitor",
            "parking entrance", "staff entrance", "employees", "gate", "訓練", "オフィス", "社員", "来訪者", "駐車入口"
        ]
        if
            announcementMarkers.contains(where: lowercased.contains),
            announcementEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "work.announcement", confidence: 0.98)
        {
            return decision
        }

        let trainingMarkers = [
            "培训", "必修课", "复训", "隐私合规课程", "学习计划", "training", "mandatory course",
            "privacy-compliance course", "learning plan", "modules", "refresher", "研修", "必修", "プライバシー研修"
        ]
        let trainingEventMarkers = [
            "课程", "测验", "考试", "完成", "课程需", "course", "assessment", "quiz", "complete", "deadline",
            "finish", "employee file", "受講", "試験", "修了", "社員台帳"
        ]
        if
            trainingMarkers.contains(where: lowercased.contains),
            trainingEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "work.training", confidence: 0.98)
        {
            return decision
        }

        // Sleeper trains contain both transport and ticketing vocabulary. The
        // issued-ticket event must win before the broader transport rule.
        let sleeperTicketContextMarkers = [
            "夜行卧铺", "卧铺列车", "overnight sleeper", "sleeper train", "夜行寝台", "寝台列車"
        ]
        let sleeperTicketEventMarkers = [
            "电子票", "电子乘车票", "e-ticket", "ticket", "签发", "issued", "qr", "乘车二维码",
            "発行", "乗車券", "乗車qr"
        ]
        if
            sleeperTicketContextMarkers.contains(where: lowercased.contains),
            sleeperTicketEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "travel.ticketing", confidence: 0.99)
        {
            return decision
        }

        let specialtyRailTicketMarkers = [
            "齿轨车", "登山铁道", "cog railway", "rack railway", "登山鉄道"
        ]
        if
            specialtyRailTicketMarkers.contains(where: lowercased.contains),
            sleeperTicketEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "travel.ticketing", confidence: 0.99)
        {
            return decision
        }

        // Tram/streetcar disruptions are transit notices even when the
        // wording mentions electrical maintenance, which otherwise resembles
        // a utility outage.
        let tramContextMarkers = [
            "有轨电车", "路面电车", "tram", "streetcar", "tramway", "路面電車"
        ]
        let tramDisruptionMarkers = [
            "供电检修", "缩短线路", "区间运行", "换乘代行巴士", "replacement bus", "power repairs",
            "shortened the tram route", "transfer", "代行バス", "区間運転", "給電点検", "乗り換え"
        ]
        if
            tramContextMarkers.contains(where: lowercased.contains),
            tramDisruptionMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "travel.transport", confidence: 0.99)
        {
            return decision
        }

        let transportMarkers = [
            "列车", "航班", "渡轮", "机场快线", "接驳巴士", "train", "flight", "ferry", "airport express", "shuttle",
            "列車", "フェリー", "空港急行", "空港連絡線", "連絡バス"
        ]
        let transportEventMarkers = [
            "晚点", "站台", "检票口", "廊桥", "delayed", "platform", "pickup", "stand", "boarding gate", "arrival stand",
            "boards at", "boarding point", "connection schedule", "shortened", "replacement bus", "route closure",
            "缩短运行区间", "换乘接驳", "代行巴士", "暂停", "区间运行", "遅れ", "ホーム", "改札口", "乗り場", "到着スポット", "区間運転", "代行バス"
        ]
        if
            transportMarkers.contains(where: lowercased.contains),
            transportEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "travel.transport", confidence: 0.98)
        {
            return decision
        }

        let specialtyTransitMarkers = [
            "缆索铁路", "缆索车", "登山电车", "funicular", "mountain tram", "cable railway",
            "ケーブルカー", "登山電車"
        ]
        let specialtyTransitDisruptionMarkers = [
            "停运", "暂停", "落石", "接驳车", "suspended", "closed", "rockfall", "replacement", "shuttle",
            "運休", "停止", "落石", "代行", "連絡バス"
        ]
        if
            specialtyTransitMarkers.contains(where: lowercased.contains),
            specialtyTransitDisruptionMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "travel.transport", confidence: 0.99)
        {
            return decision
        }

        let railTicketMarkers = [
            "高铁电子票", "电子票", "high-speed rail e-ticket", "e-ticket", "rail e-ticket",
            "電子乗車券", "高速鉄道", "高速鉄道の電子"
        ]
        let railTicketEventMarkers = [
            "出票", "检票二维码", "issued", "gate qr", "qr code", "発券", "改札用qr", "表示"
        ]
        if
            railTicketMarkers.contains(where: lowercased.contains),
            railTicketEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "travel.ticketing", confidence: 0.98)
        {
            return decision
        }

        let ferryCabinTicketMarkers = [
            "渡轮卧铺", "夜航渡轮", "夜船卧铺", "ferry berth", "ferry cabin", "overnight ferry",
            "フェリー寝台", "夜行フェリー", "船室券"
        ]
        if
            ferryCabinTicketMarkers.contains(where: lowercased.contains),
            sleeperTicketEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "travel.ticketing", confidence: 0.99)
        {
            return decision
        }

        let portTicketingContextMarkers = [
            "港口", "码头", "登船牌", "登船证", "port terminal", "ferry terminal", "boarding pass",
            "港の案内", "旅客ターミナル", "乗船証", "乗船券"
        ]
        let portTicketingProcessMarkers = [
            "人工柜台", "证件", "核验", "发放", "counter", "identity document", "verify", "issued",
            "有人窓口", "本人確認", "発行"
        ]
        if
            portTicketingContextMarkers.contains(where: lowercased.contains),
            portTicketingProcessMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "travel.ticketing", confidence: 0.99)
        {
            return decision
        }

        let medicalMarkers = [
            "复诊", "就诊", "医院预约", "处方", "药房", "检验报告", "检验中心", "血液检查", "检查报告",
            "follow-up appointment", "hospital confirms", "prescription", "pharmacy", "laboratory report", "laboratory",
            "hospital lab", "test report", "blood test", "lab report", "thyroid test", "肝功能", "甲状腺",
            "再診予約", "病院から", "検査室", "検査センター", "血液検査", "検査報告",
            "処方", "薬局", "検査結果", "放射科", "影像复核", "radiology", "imaging review", "放射線科", "画像再確認"
        ]
        if medicalMarkers.contains(where: lowercased.contains), let label = SiftTaxonomy.leaf(id: "life.medical") {
            return ClassificationDecision(
                labelID: label.id, labelTitle: label.title, groupID: label.groupId,
                groupTitle: label.groupTitle, confidence: 0.97,
                systemAction: label.systemAction, source: .model
            )
        }

        let wastewaterSourceMarkers = [
            "排水公司", "污水处理", "wastewater utility", "wastewater department", "sewer utility",
            "下水道事業者", "下水道局"
        ]
        let wastewaterEventMarkers = [
            "管道清淤", "清淤", "限制排水", "sewer cleaning", "drain discharge",
            "sewer maintenance", "管清掃", "下水道清掃", "大量排水"
        ]
        if
            wastewaterSourceMarkers.contains(where: lowercased.contains),
            wastewaterEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "life.utility", confidence: 0.99)
        {
            return decision
        }

        let utilitySourceMarkers = [
            "供水公司", "供电公司", "电力公司", "供热公司", "供冷公司", "燃气公司", "water utility", "power utility",
            "district-heating utility", "district-cooling utility", "gas utility", "水道局", "電力会社", "地域暖房会社", "地域冷房会社", "ガス会社"
        ]
        let utilityDetailedEventMarkers = [
            "煮沸", "管网", "管网冲洗", "供水", "供电", "停暖", "停电", "暂停供气", "boil notice", "network flushing",
            "electricity", "heat", "gas service", "pressure-test", "pressure test", "pipe flushing", "管洗浄", "配管洗浄", "給水", "停電", "暖房", "圧力試験"
        ]
        if
            utilitySourceMarkers.contains(where: lowercased.contains),
            utilityDetailedEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "life.utility", confidence: 0.98)
        {
            return decision
        }

        let weatherSourceMarkers = [
            "气象台", "气象部门", "天气预报", "weather office", "weather service", "weather bureau", "気象台", "気象当局"
        ]
        let weatherEventMarkers = [
            "预警", "寒潮", "霜冻", "大风", "warning", "advisory", "cold-wave", "below zero", "freezing",
            "強風", "寒波", "注意報", "氷点下"
        ]
        if
            weatherSourceMarkers.contains(where: lowercased.contains),
            weatherEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "life.weather", confidence: 0.98)
        {
            return decision
        }

        let bankPaymentMarkers = [
            "口座末尾", "account ending", "账户尾号", "扣款", "debited", "支払いました", "支払い",
            "口座から"
        ]
        let bankMerchantMarkers = [
            "商户", "可用资金", "merchant", "available funds", "書店", "店舗", "店"
        ]
        if
            bankPaymentMarkers.contains(where: lowercased.contains),
            bankMerchantMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.bank", confidence: 0.97)
        {
            return decision
        }

        let trafficMarkers = [
            "道路", "隧道", "高架", "匝道", "车辆", "通行", "交通", "road closure", "road work", "road maintenance",
            "roadway", "lane", "tunnel", "bridge", "detour", "traffic", "通行止め"
        ]
        let trafficEventMarkers = [
            "封闭", "施工", "检修", "绕行", "管制", "closure", "closed", "maintenance", "detour",
            "restrict", "road works", "規制", "補修", "工事", "迂回"
        ]
        if
            trafficMarkers.contains(where: lowercased.contains),
            trafficEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "government.traffic", confidence: 0.98)
        {
            return decision
        }

        let carrierServiceMarkers = [
            "运营商", "通信公司", "移动网络", "语音网络", "核心网", "交换设备", "carrier",
            "mobile provider", "voice service", "voice network", "telecom", "通信会社", "携帯ネットワーク",
            "音声ネットワーク"
        ]
        let carrierServiceEventMarkers = [
            "升级", "维护", "切换", "中断", "恢复", "upgrad", "maintenance", "unavailable",
            "migrat", "service node", "保守", "更新", "復旧", "切り替え"
        ]
        if
            carrierServiceMarkers.contains(where: lowercased.contains),
            carrierServiceEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "carrier.service", confidence: 0.98)
        {
            return decision
        }

        let incomeMarkers = [
            "工资", "薪资", "绩效奖金", "奖金", "工资卡", "payroll", "salary", "bonus", "wage",
            "給与", "賞与"
        ]
        let incomeCompletionMarkers = [
            "发放", "入账", "汇入", "存入", "到账", "credited", "deposited", "paid", "transfer", "振り込",
            "入金"
        ]
        if
            incomeMarkers.contains(where: lowercased.contains),
            incomeCompletionMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.income", confidence: 0.98)
        {
            return decision
        }

        let specificSocialBenefitMarkers = [
            "生育津贴", "伤残津贴", "maternity-benefit", "disability-benefit", "maternity benefit",
            "disability benefit", "disability allowance", "caregiver allowance", "caregiver-allowance", "照护津贴", "伤残补助", "出産給付", "障害給付", "介護手当"
        ]
        let specificSocialStatusMarkers = [
            "资格", "审核", "review", "eligibility", "通过", "passed", "记录", "account", "給付履歴", "資格審査"
        ]
        if
            specificSocialBenefitMarkers.contains(where: lowercased.contains),
            specificSocialStatusMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "government.social_security", confidence: 0.99)
        {
            return decision
        }

        let insuranceMarkers = [
            "保险", "理赔", "赔付", "报销", "claim", "insurer", "benefit", "reimbursement", "保険", "給付"
        ]
        let insuranceCompletionMarkers = [
            "审核通过", "完成", "到账", "approved", "complete", "payment", "transfer", "支払", "入金"
        ]
        if
            insuranceMarkers.contains(where: lowercased.contains),
            insuranceCompletionMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "finance.insurance", confidence: 0.98)
        {
            return decision
        }

        let volcanoAuthorityMarkers = [
            "火山防灾", "volcano emergency", "volcano officials", "volcano authority", "火山防災"
        ]
        let volcanoSafetyMarkers = [
            "演练警报", "drill alarm", "避难所", "indoor shelter", "shelter", "佩戴口罩", "wearing a mask",
            "蓝色路线", "blue route", "青い経路", "屋内避難所", "マスク"
        ]
        if
            volcanoAuthorityMarkers.contains(where: lowercased.contains),
            volcanoSafetyMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "government.reminder", confidence: 0.99)
        {
            return decision
        }

        let utilityMarkers = [
            "供水", "水务", "水道", "燃气", "供气", "供冷", "电力", "供电", "utility", "water utility",
            "district cooling", "gas", "power company", "水道局", "地域冷房", "ガス設備", "電力会社"
        ]
        let utilityEventMarkers = [
            "检修", "维护", "暂停", "停止", "恢复", "管线", "maintenance", "suspend", "service",
            "restore", "pipe work", "pressure test", "工事", "復旧", "圧力試験"
        ]
        if
            utilityMarkers.contains(where: lowercased.contains),
            utilityEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "life.utility", confidence: 0.98)
        {
            return decision
        }

        let flexibleAttendanceContextMarkers = [
            "弹性排班", "弹性工时", "压缩工作周", "flexible schedule", "flexible-schedule", "flex-hours",
            "compressed workweek", "compressed-workweek", "時差勤務", "フレックス勤務", "週4日勤務"
        ]
        let flexibleAttendanceEventMarkers = [
            "签到时间", "考勤规则", "clock-in", "attendance rules", "timekeeping", "打刻時刻", "勤怠ルール"
        ]
        if
            flexibleAttendanceContextMarkers.contains(where: lowercased.contains),
            flexibleAttendanceEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "work.attendance", confidence: 0.99)
        {
            return decision
        }

        let meetingMarkers = [
            "会议", "例会", "评审会", "复盘会", "stand-up", "standup", "跨区域", "cross-region stand-up", "meeting", "review", "retrospective", "project sync", "会議", "レビュー"
        ]
        let meetingChangeMarkers = [
            "改到", "延期", "延后", "更新", "链接", "日历", "moved", "rescheduled", "updated", "calendar",
            "link", "変更", "遅く"
        ]
        if
            meetingMarkers.contains(where: lowercased.contains),
            meetingChangeMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "work.meeting", confidence: 0.97)
        {
            return decision
        }

        let lodgingMarkers = [
            "酒店", "住宿", "度假村", "客栈", "hotel", "resort", "lodging", "accommodation", "stay", "inn", "guesthouse",
            "宿泊", "ホテル", "旅館", "民宿", "の宿"
        ]
        let lodgingEventMarkers = [
            "确认", "已预订", "入住", "房间", "订单", "confirmed", "booked", "check-in", "room",
            "reservation confirmed", "予約確定", "予約済み", "確定", "チェックイン", "確保"
        ]
        if
            lodgingMarkers.contains(where: lowercased.contains),
            lodgingEventMarkers.contains(where: lowercased.contains),
            let decision = forcedDecision(labelID: "travel.tourism", confidence: 0.97)
        {
            return decision
        }
        return nil
    }

    public static func personalConversationSignal(in body: String) -> Bool {
        let questionMarkers = ["吗？", "吗?", "did you", "would you", "are we", "can you", "ますか", "ましたか", "でしょうか"]
        let personalMarkers = ["我", "你", "一起", " i ", "i ", " you", "we ", "一緒", "届き", "送った"]
        let casualContextMarkers = ["群里", "聊天", "周末", "晚上", "一起", "链接", "会议", "link", "room", "together", "weekend", "chat", "リンク", "会議", "週末", "映画代"]
        let directTransferMarkers = [
            "转给你", "转回给你", "带给你", "放在玄关", "帮我拿", "sent you", "sent back",
            "left the membership", "when you pass by", "bring it when", "返したよ", "送ったよ",
            "家に着いたら", "忘れていった", "玄関の引き出し", "持ってきて", "持っていくね", "持っていきます"
        ]
        return directTransferMarkers.contains(where: body.contains)
            || (
                questionMarkers.contains(where: body.contains)
                    && personalMarkers.contains(where: body.contains)
                    && casualContextMarkers.contains(where: body.contains)
            )
    }

    private func fallbackDecision(confidence: Double) -> ClassificationDecision {
        let leaf = SiftTaxonomy.leaf(id: "transaction.other") ?? SiftTaxonomy.leaves[0]
        return ClassificationDecision(
            labelID: leaf.id,
            labelTitle: leaf.title,
            groupID: leaf.groupId,
            groupTitle: leaf.groupTitle,
            confidence: confidence,
            systemAction: .none,
            source: .fallback
        )
    }

    private func looksLikePersonalConversation(_ body: String) -> Bool {
        Self.personalConversationSignal(in: body)
    }

    private func bestMatch(in body: String) -> (label: LeafLabel, confidence: Double) {
        // Keyword fallback for when no model is bundled. Chinese first, plus a
        // thin layer of high-precision English keywords for multilingual SMS.
        let loanShortcutMarkers = [
            "免征信", "免审核", "无视征信", "no credit check", "no-credit-check",
            "no-review loan", "審査不要", "審査なし", "無審査"
        ]
        let advanceFeeMarkers = [
            "账户激活费", "激活费用", "解冻费", "保证金", "account activation charge",
            "activation fee", "unlock charge", "security deposit", "口座有効化手数料",
            "解除手数料", "保証金"
        ]
        let impersonationMarkers = [
            "冒充", "假冒", "所谓客服", "自称客服", "impersonating", "posing as",
            "supposed support", "fake support", "装い", "名乗る", "偽の窓口"
        ]
        let credentialOrPrepaymentMarkers = [
            "短信验证码", "动态口令", "先支付", "先缴", "登记费", "认证费", "保证金",
            "sms code", "one-time password", "advance fee", "registration fee", "deposit",
            "認証番号", "ワンタイムパスワード", "先払い", "申請料", "保証金"
        ]
        let refundProblemMarkers = [
            "退款失败", "退款卡住", "退款异常", "refund failed", "refund is stuck",
            "refund problem", "返金失敗", "返金処理の停止", "返金できない"
        ]
        let credentialTransferMarkers = [
            "把验证码发", "转发验证码", "验证码转发", "send the verification code",
            "forward the verification code", "forward the code", "認証コードを転送",
            "認証番号を送", "コードを転送", "認証コードを送"
        ]
        if
            (
                loanShortcutMarkers.contains(where: body.contains)
                    && advanceFeeMarkers.contains(where: body.contains)
            ) || (
                impersonationMarkers.contains(where: body.contains)
                    && credentialOrPrepaymentMarkers.contains(where: body.contains)
            ) || (
                refundProblemMarkers.contains(where: body.contains)
                    && credentialTransferMarkers.contains(where: body.contains)
            ),
            let label = SiftTaxonomy.leaf(id: "spam")
        {
            return (label, 0.98)
        }

        let pointsMarkers = ["积分", "reward points", "rewards points", "member points", "member-points", "points balance", "ポイント"]
        let pointsCompletionMarkers = [
            "累计", "获得", "新增", "余额为", "余额已", "added", "earned",
            "balance is now", "available balance", "were posted", "was posted", "加算", "獲得", "残高は"
        ]
        if
            pointsMarkers.contains(where: body.contains),
            pointsCompletionMarkers.contains(where: body.contains),
            let label = SiftTaxonomy.leaf(id: "transaction.points")
        {
            return (label, 0.95)
        }

        let carrierPlanChangeMarkers = [
            "更换家庭", "升级家庭", "共享套餐", "move to the shared", "upgrade the shared",
            "family mobile plan", "家族共有プラン", "家族向けプラン"
        ]
        let carrierPlanBenefitMarkers = [
            "增加", "新增", "获赠", "赠送流量", "extra line", "bonus data",
            "receive", "追加回線", "特典データ", "データが付き"
        ]
        if
            carrierPlanChangeMarkers.contains(where: body.contains),
            carrierPlanBenefitMarkers.contains(where: body.contains),
            let label = SiftTaxonomy.leaf(id: "carrier.promotion")
        {
            return (label, 0.96)
        }

        let orderMarkers = ["订单", "order", "注文"]
        let orderPaidMarkers = ["已付款", "支付完成", "已完成付款", "is paid", "payment is complete", "支払い済み", "決済済み"]
        let orderFulfillmentMarkers = [
            "仓库", "工厂", "发货", "发运", "打包", "warehouse", "workshop", "factory", "pack",
            "ship", "倉庫", "工房", "工場", "梱包", "発送"
        ]
        if
            orderMarkers.contains(where: body.contains),
            orderPaidMarkers.contains(where: body.contains),
            orderFulfillmentMarkers.contains(where: body.contains),
            let label = SiftTaxonomy.leaf(id: "transaction.order")
        {
            return (label, 0.96)
        }

        let verificationContextMarkers = [
            "验证码", "code", "認証コード", "確認コード"
        ]
        let verificationSafetyMarkers = [
            "分钟内有效", "请勿转发", "请勿告诉", "valid for", "do not share",
            "do not forward", "分間有効", "転送しない", "教えない"
        ]
        if
            verificationContextMarkers.contains(where: body.contains),
            verificationSafetyMarkers.contains(where: body.contains),
            let label = SiftTaxonomy.leaf(id: "verification")
        {
            return (label, 0.99)
        }

        let carrierBillingPhrases = [
            "话费余额", "通信账单", "话费账单", "通信费用", "mobile bill",
            "communications bill", "broadband bill", "airtime balance", "通信料金",
            "家庭通信料金", "料金残高", "月額請求"
        ]
        let carrierContexts = [
            "中国移动", "中国联通", "中国电信", "中国广电", "运营商", "通信账户",
            "mobile", "carrier", "airtime", "wireless", "cellular", "telecom", "communications",
            "broadband", "モバイル", "通信", "携帯"
        ]
        let billingSignals = [
            "账单", "缴费", "充值成功", "欠费", "应缴", "余额", "bill", "billing",
            "statement", "payment received", "autopay", "請求", "支払い", "残高"
        ]
        if
            carrierBillingPhrases.contains(where: body.contains)
                || (
                    carrierContexts.contains(where: body.contains)
                        && billingSignals.contains(where: body.contains)
                ),
            let label = SiftTaxonomy.leaf(id: "carrier.billing")
        {
            return (label, 0.94)
        }

        // A card identifier describes the payment instrument, not the account
        // event. Merchant purchases belong to consumption; statements and
        // repayments remain under the credit-card account label.
        let cardMarkers = ["信用卡", "credit card", "card ending", "クレジットカード", "カード"]
        let purchaseMarkers = [
            "消费", "购买", "购物", "刷卡", "purchase", "purchased", "grocery",
            "shopping", "merchant", "利用", "購入", "買い物"
        ]
        let accountEventMarkers = [
            "账单", "月结", "还款", "最低还款", "到期还款", "逾期", "statement",
            "repayment", "payment due", "refund", "退款", "退回", "返金"
        ]
        if
            cardMarkers.contains(where: body.contains),
            purchaseMarkers.contains(where: body.contains),
            !accountEventMarkers.contains(where: body.contains),
            let label = SiftTaxonomy.leaf(id: "finance.consumption")
        {
            return (label, 0.95)
        }

        let cloudResourceMarkers = [
            "云数据库", "云服务器", "云资源", "实例id", "对象存储",
            "cloud database", "managed database", "cloud server", "cloud resource",
            "virtual machine", "object storage", "クラウドdb", "クラウドデータベース",
            "仮想サーバー", "オブジェクトストレージ", "インスタンスid"
        ]
        let cloudExpiryRiskMarkers = [
            "到期", "停止服务", "停机", "资源将会被释放", "数据不可恢复", "续费",
            "expires", "expiry", "renew", "suspended", "purged", "deleted", "data loss",
            "利用期限", "契約がまもなく終了", "停止", "削除", "消去", "更新してください"
        ]
        if
            cloudResourceMarkers.contains(where: body.contains),
            cloudExpiryRiskMarkers.contains(where: body.contains),
            let label = SiftTaxonomy.leaf(id: "work.alert")
        {
            return (label, 0.96)
        }

        let operationalResourceMarkers = [
            "生产日志", "日志索引", "接口证书", "消息队列", "production log", "production database",
            "log index", "certificate", "api certificate", "message queue", "本番ログ", "本番データベース",
            "ログ索引", "証明書", "api証明書", "メッセージキュー"
        ]
        let operationalRiskMarkers = [
            "配额", "容量不足", "停止写入", "过期", "quota", "retention", "stop accepting writes",
            "expire", "容量", "書き込み", "期限", "失効"
        ]
        if
            operationalResourceMarkers.contains(where: body.contains),
            operationalRiskMarkers.contains(where: body.contains),
            let label = SiftTaxonomy.leaf(id: "work.alert")
        {
            return (label, 0.96)
        }

        let governmentSources = [
            "公安", "政府", "政务", "应急管理", "消防", "卫健", "卫生健康", "卫生部门", "疾控",
            "教育局", "教育部门", "市场监管", "社区", "街道办", "反诈中心", "水务",
            "生态环境部门", "环境部门",
            "消费者权益保护", "police", "public health", "health department", "fire department",
            "fire and rescue service", "emergency management", "education department",
            "food safety authority", "fraud prevention office", "consumer protection office", "environmental authority",
            "community", "water authority", "emergency services", "警察", "消防", "消防本部", "保健当局", "保健部門", "保健所",
            "应急部门", "防災当局", "防災機関", "環境当局", "環境部門", "教育委員会", "食品安全当局", "詐欺対策", "消費生活センター", "自治体", "水道局"
        ]
        let civicReminderSignals = [
            "提示", "提醒", "温馨提醒", "倡议", "请勿", "预防", "防范", "注意安全",
            "远离", "守护", "安全监护", "remind", "advise", "urge", "asks residents",
            "safety message", "avoid", "stay safe", "からのお知らせ", "からのお願い",
            "からの注意", "よう呼びかけ", "よう案内"
        ]
        let specializedGovernmentSignals = [
            "税务", "退税", "社保", "医保", "公积金", "法院", "司法", "违章", "驾驶证",
            "政策", "新规", "条例", "tax", "social insurance", "court", "licence renewal",
            "policy", "regulation", "税務", "社会保険", "裁判所", "免許更新", "政策", "制度"
        ]
        if
            governmentSources.contains(where: body.contains),
            civicReminderSignals.contains(where: body.contains),
            !specializedGovernmentSignals.contains(where: body.contains),
            let label = SiftTaxonomy.leaf(id: "government.reminder")
        {
            return (label, 0.94)
        }

        let disasterReminderSignals = [
            "疏散演练", "避难演练", "evacuation drill", "evacuation-drill", "evacuation exercise",
            "避難訓練", "避難演習", "避難誘導", "サイレン"
        ]
        if
            governmentSources.contains(where: body.contains),
            disasterReminderSignals.contains(where: body.contains),
            let label = SiftTaxonomy.leaf(id: "government.reminder")
        {
            return (label, 0.99)
        }

        let rules: [(labelID: String, keywords: [String], confidence: Double)] = [
            ("verification", ["验证码", "动态码", "校验码", "verification code", "security code", "otp", "passcode", "認証コード", "確認コード", "ワンタイム"], 0.99),
            ("spam", ["刷单", "贷款秒批", "无视征信", "免审核", "免征信", "先交保证金", "解冻手续费", "账户激活费", "安全账户", "涉嫌洗钱", "代办证件", "彩票内幕", "中奖通知", "点击链接完成认证", "you won", "winner", "claim your prize", "your account will be frozen", "guaranteed returns", "no credit check", "no-credit-check", "no-review loan", "pay a deposit", "account activation charge", "unlock charge", "審査なし即日融資", "審査不要", "無審査融資", "口座有効化手数料", "保証金", "解除手数料", "当選しました", "至急ご確認ください"], 0.95),
            ("transaction.points", ["积分到账", "获得积分", "奖励积分", "积分余额已更新", "积分抵扣成功", "points added", "points earned", "reward points", "reward balance updated", "ポイントが加算", "ポイント獲得", "ポイント利用"], 0.93),
            ("carrier.promotion", ["电信积分", "移动积分", "联通积分", "通信积分", "运营商积分", "话费积分", "carrier rewards", "mobile rewards", "airtime voucher", "通信ポイント", "キャリアポイント"], 0.94),
            ("transaction.order", ["游戏道具订单", "装备订单", "订单中的皮肤", "订单中的金币", "订单已支付", "已付款，仓库", "订单已进入验号", "item order is paid", "order has been paid", "will leave the warehouse", "warehouse will dispatch", "gear order is paid", "items in your order", "trade is in verification", "アイテム注文", "装備注文", "注文したスキン", "注文は支払い済み", "倉庫から発送", "取引は確認段階"], 0.95),
            ("promotion", ["退订", "回复t", "推广", "营销", "广告", "优惠", "限时", "活动", "折扣", "领券", "促销", "赠送", "加送", "积分商城", "银行商城", "积分兑换好礼", "首充双倍", "充值返利", "充值节", "赛季通行证", "限定皮肤", "游戏礼包", "游戏道具", "装备交易", "金币交易", "账号交易", "武库轮换", "武库换新", "更新货架", "即开即售", "寄售季", "新品发布", "新品上线", "新房源", "预约看房", "租金优惠", "贷款利率优惠", "服装折扣", "超市特卖", "% off", "flash sale", "discount", "voucher", "reply stop", "rewards mall", "bank marketplace", "game server", "top-up bonus", "game top-up", "season pass", "in-game item", "armory rotation", "armory refresh", "instant listing", "consignment event", "new product", "new rental", "loan rate offer", "fashion sale", "grocery member day", "supermarket sale", "ポイントモール", "銀行モール", "新サーバー", "初回チャージ", "ゲームチャージ", "武器庫ローテーション", "武器庫更新", "委託販売イベント", "新商品", "新着物件", "先行予約", "スマートロック", "取付サービス", "金利優遇", "ゲームアイテム", "衣料品セール", "スーパー特売"], 0.94),
            ("finance.refund", ["退款", "退回", "原路返回", "refund", "返金"], 0.96),
            ("finance.consumption", ["分期购买", "分期付款成功", "分期支付", "purchase alert", "purchase completed", "installment purchase", "buy now pay later", "分割購入", "分割払いで購入"], 0.95),
            ("finance.income", ["工资到账", "转账到账", "代发", "存入现金", "收到转账", "salary", "deposited"], 0.93),
            ("finance.bank", ["银行", "账户", "余额", "转账", "扣款", "debited", "credited", "balance"], 0.82),
            ("finance.credit_card", ["信用卡", "账单", "还款", "最低还款", "credit card", "statement", "repayment received", "payment due", "applied to your card", "お支払いを確認", "返済"], 0.88),
            ("life.medical", ["复诊", "就诊", "医院预约", "follow-up appointment", "hospital confirms", "再診予約", "病院から"], 0.94),
            ("life.express", ["快递", "包裹", "派送", "签收", "out for delivery", "parcel", "package", "荷物", "配送", "配達"], 0.91),
            ("life.logistics", ["物流", "运单", "发货", "揽收", "shipment", "in transit"], 0.9),
            ("life.pickup_code", ["取件码", "自提", "驿站", "柜机", "pickup code", "locker"], 0.97),
            ("life.weather", ["天气", "预警", "暴雨", "台风", "高温", "寒潮", "weather warning", "heat advisory"], 0.92),
            ("travel.ticketing", ["票务", "机票", "车票", "船票", "登机", "登船", "出票", "值机", "值船", "ticketed", "check-in", "boarding", "乗船券", "乗船", "チェックイン"], 0.91),
            ("travel.transport", ["公交", "地铁", "航班", "列车", "交通", "flight delay"], 0.83),
            ("work.meeting", ["会议", "腾讯会议", "zoom", "会议室", "meeting"], 0.9),
            ("work.approval", ["审批", "请假单", "调休", "报销审批", "oa", "approval"], 0.9),
            ("work.attendance", ["打卡", "考勤", "外勤", "排班", "加班记录", "clock-out", "roster"], 0.9),
            ("work.announcement", ["公司公告", "全员通知", "团建", "组织公告", "all hands"], 0.85),
            ("work.training", ["培训", "课程", "认证", "考试提醒", "training"], 0.85),
            ("work.reminder", ["提醒", "待办", "日程", "周报", "to-do", "due by"], 0.8),
            ("work.alert", ["告警", "异常", "风险", "超限", "pager", "system alert", "production alert", "cloud service alert", "cloud cache", "build failed", "retention capacity", "certificate expires", "クラウドサービス", "クラウドキャッシュ", "本番監視アラート", "保管容量"], 0.93),
            ("carrier.call_reminder", ["来电提醒", "missed call", "voicemail"], 0.95),
            ("carrier.data_reminder", ["流量", "套餐", "剩余", "已用", "data plan", "gb left", "top up"], 0.9),
            ("carrier.service", ["办理", "套餐", "变更", "服务", "roaming"], 0.84),
            ("government.traffic", ["交警", "12123", "违章", "驾驶证", "etc", "车辆年检", "toll charge"], 0.9),
            ("government.tax", ["税务", "电子税务", "增值税", "个税", "退税", "发票领用", "tax refund"], 0.9),
            ("government.social_security", ["社保", "医保", "公积金", "缴存", "social insurance"], 0.9),
            ("government.court", ["法院", "司法", "立案", "庭审", "执行通知", "court notice"], 0.9),
            ("government.policy", ["政策", "国务院", "新规", "条例", "通告"], 0.85),
            ("transaction.message", ["客户端更新", "桌面客户端", "更新完成", "客户端维护", "离线同步", "通知设置", "浏览器更新", "client update", "desktop client", "desktop app", "client maintenance", "browser update", "browser maintenance", "upgrade finished", "offline sync", "attachment preview", "update is complete", "notification settings", "デスクトップアプリ", "アプリの更新", "ブラウザの更新", "ブラウザの保守", "更新が完了", "オフライン同期", "添付ファイル", "通知設定", "ゲームクライアント"], 0.92),
            ("government.notice", ["通知", "政务", "公告"], 0.83),
            ("transaction.account_security", ["new device", "sign-in detected", "password was changed"], 0.9),
            ("transaction.message", ["游戏版本更新", "游戏客户端已更新", "版本维护完成", "game version update", "game client is up to date", "maintenance is complete", "ゲームのバージョン更新", "ゲームクライアントは最新版", "メンテナンスが完了"], 0.92)
        ]

        for item in rules {
            if item.keywords.contains(where: { body.contains($0) }), let label = SiftTaxonomy.leaf(id: item.labelID) {
                return (label, item.confidence)
            }
        }

        if let label = SiftTaxonomy.leaf(id: "transaction.message") {
            return (label, 0.55)
        }
        return (SiftTaxonomy.leaves[0], 0.5)
    }
}

public struct CascadingClassifier: MessageClassifier {
    public let primary: any MessageClassifier
    public let fallback: any MessageClassifier
    public let primaryThreshold: Double

    public init(
        primary: any MessageClassifier,
        fallback: any MessageClassifier,
        primaryThreshold: Double = 0.72
    ) {
        self.primary = primary
        self.fallback = fallback
        self.primaryThreshold = primaryThreshold
    }

    public func classify(sender: String?, body: String) -> ClassificationDecision {
        if let forced = HeuristicClassifier.highPrecisionDecision(for: body) {
            return forced
        }
        let primaryDecision = primary.classify(sender: sender, body: body)
        if ModelOutputContract.isAbstainLabel(primaryDecision.labelID) {
            return primaryDecision
        }
        if primaryDecision.source != .fallback, primaryDecision.confidence >= primaryThreshold {
            return primaryDecision
        }
        return fallback.classify(sender: sender, body: body)
    }
}

public struct ClassificationPipeline: Sendable {
    public let ruleEngine: RuleEngine
    public let classifier: any MessageClassifier

    public init(ruleEngine: RuleEngine = .init(), classifier: any MessageClassifier = HeuristicClassifier()) {
        self.ruleEngine = ruleEngine
        self.classifier = classifier
    }

    public func classify(sender: String?, body: String, rules: [CustomRule]) -> ClassificationDecision {
        if let match = ruleEngine.match(sender: sender, body: body, rules: rules) {
            let action = match.rule.action
            let label = SiftTaxonomy.leaf(id: action.decisionLabelID) ?? SiftTaxonomy.leaves[0]
            return ClassificationDecision(
                labelID: label.id,
                labelTitle: label.title,
                groupID: label.groupId,
                groupTitle: label.groupTitle,
                confidence: 1,
                systemAction: action.systemAction,
                source: .rule
            )
        }

        let decision = classifier.classify(sender: sender, body: body)
        if ModelOutputContract.isAbstainLabel(decision.labelID) {
            return decision
        }
        if decision.confidence < 0.6 {
            if let fallback = SiftTaxonomy.leaf(id: "transaction.other") {
                return ClassificationDecision(
                    labelID: fallback.id,
                    labelTitle: fallback.title,
                    groupID: fallback.groupId,
                    groupTitle: fallback.groupTitle,
                    confidence: decision.confidence,
                    systemAction: .none,
                    source: .fallback
                )
            }
        }
        return decision
    }
}
