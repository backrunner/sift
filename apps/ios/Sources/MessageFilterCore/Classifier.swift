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

public struct HeuristicClassifier: MessageClassifier {
    public var confidenceThreshold: Double

    public init(confidenceThreshold: Double = 0.65) {
        self.confidenceThreshold = confidenceThreshold
    }

    public func classify(sender: String?, body: String) -> ClassificationDecision {
        let lowercased = body.lowercased()
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

    private func bestMatch(in body: String) -> (label: LeafLabel, confidence: Double) {
        // Keyword fallback for when no model is bundled. Chinese first, plus a
        // thin layer of high-precision English keywords for multilingual SMS.
        let carrierBillingPhrases = [
            "话费余额", "通信账单", "话费账单", "通信费用", "mobile bill",
            "airtime balance", "通信料金", "料金残高", "月額請求"
        ]
        let carrierContexts = [
            "中国移动", "中国联通", "中国电信", "中国广电", "运营商", "通信账户",
            "mobile", "carrier", "airtime", "wireless", "cellular", "telecom",
            "モバイル", "通信", "携帯"
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

        let rules: [(labelID: String, keywords: [String], confidence: Double)] = [
            ("verification", ["验证码", "动态码", "校验码", "verification code", "security code", "otp", "passcode", "認証コード", "確認コード", "ワンタイム"], 0.99),
            ("spam", ["刷单", "贷款秒批", "无视征信", "先交保证金", "安全账户", "涉嫌洗钱", "代办证件", "彩票内幕", "中奖通知", "点击链接完成认证", "you won", "winner", "claim your prize", "your account will be frozen", "guaranteed returns", "no credit check", "pay a deposit", "審査なし即日融資", "保証金", "当選しました", "至急ご確認ください"], 0.95),
            ("transaction.points", ["积分到账", "获得积分", "积分余额已更新", "积分抵扣成功", "points added", "points earned", "reward balance updated", "ポイントが加算", "ポイント獲得", "ポイント利用"], 0.93),
            ("carrier.promotion", ["电信积分", "移动积分", "联通积分", "通信积分", "运营商积分", "话费积分", "carrier rewards", "mobile rewards", "airtime voucher", "通信ポイント", "キャリアポイント"], 0.94),
            ("transaction.order", ["游戏道具订单", "装备订单", "订单中的皮肤", "订单中的金币", "订单已支付", "订单已进入验号", "item order is paid", "gear order is paid", "items in your order", "trade is in verification", "アイテム注文", "装備注文", "注文したスキン", "取引は確認段階"], 0.95),
            ("promotion", ["退订", "回复t", "推广", "营销", "广告", "优惠", "限时", "活动", "折扣", "领券", "促销", "积分商城", "银行商城", "积分兑换好礼", "首充双倍", "充值返利", "充值节", "赛季通行证", "限定皮肤", "游戏礼包", "游戏道具", "装备交易", "金币交易", "账号交易", "武库轮换", "武库换新", "更新货架", "即开即售", "寄售季", "新品发布", "新品上线", "新房源", "预约看房", "租金优惠", "贷款利率优惠", "服装折扣", "超市特卖", "% off", "flash sale", "discount", "voucher", "reply stop", "rewards mall", "bank marketplace", "game server", "top-up bonus", "game top-up", "season pass", "in-game item", "armory rotation", "armory refresh", "instant listing", "consignment event", "new product", "new rental", "loan rate offer", "fashion sale", "grocery member day", "supermarket sale", "ポイントモール", "銀行モール", "新サーバー", "初回チャージ", "ゲームチャージ", "武器庫ローテーション", "武器庫更新", "委託販売イベント", "新商品", "新着物件", "金利優遇", "ゲームアイテム", "衣料品セール", "スーパー特売"], 0.94),
            ("finance.refund", ["退款", "退回", "原路返回", "refund"], 0.96),
            ("finance.consumption", ["分期购买", "分期付款成功", "分期支付", "purchase alert", "purchase completed", "installment purchase", "buy now pay later", "分割購入", "分割払いで購入"], 0.95),
            ("finance.income", ["工资到账", "转账到账", "代发", "存入现金", "收到转账", "salary", "deposited"], 0.93),
            ("finance.bank", ["银行", "账户", "余额", "转账", "扣款", "debited", "credited", "balance"], 0.82),
            ("finance.credit_card", ["信用卡", "账单", "还款", "最低还款", "credit card", "statement", "repayment received", "payment due", "applied to your card", "お支払いを確認", "返済"], 0.88),
            ("life.express", ["快递", "包裹", "派送", "签收", "out for delivery", "parcel", "package"], 0.91),
            ("life.logistics", ["物流", "运单", "发货", "揽收", "shipment", "in transit"], 0.9),
            ("life.pickup_code", ["取件码", "自提", "驿站", "柜机", "pickup code", "locker"], 0.97),
            ("life.weather", ["天气", "预警", "暴雨", "台风", "高温", "寒潮", "weather warning", "heat advisory"], 0.92),
            ("travel.ticketing", ["票务", "机票", "车票", "登机", "出票", "ticketed", "check-in", "boarding"], 0.91),
            ("travel.transport", ["公交", "地铁", "航班", "列车", "交通", "flight delay"], 0.83),
            ("work.meeting", ["会议", "腾讯会议", "zoom", "会议室", "meeting"], 0.9),
            ("work.approval", ["审批", "请假单", "调休", "报销审批", "oa", "approval"], 0.9),
            ("work.attendance", ["打卡", "考勤", "外勤", "排班", "加班记录", "clock-out", "roster"], 0.9),
            ("work.announcement", ["公司公告", "全员通知", "团建", "组织公告", "all hands"], 0.85),
            ("work.training", ["培训", "课程", "认证", "考试提醒", "training"], 0.85),
            ("work.reminder", ["提醒", "待办", "日程", "周报", "to-do", "due by"], 0.8),
            ("work.alert", ["告警", "异常", "风险", "超限", "pager", "system alert", "build failed"], 0.93),
            ("carrier.call_reminder", ["来电提醒", "missed call", "voicemail"], 0.95),
            ("carrier.data_reminder", ["流量", "套餐", "剩余", "已用", "data plan", "gb left", "top up"], 0.9),
            ("carrier.service", ["办理", "套餐", "变更", "服务", "roaming"], 0.84),
            ("government.traffic", ["交警", "12123", "违章", "驾驶证", "etc", "车辆年检", "toll charge"], 0.9),
            ("government.tax", ["税务", "电子税务", "增值税", "个税", "退税", "发票领用", "tax refund"], 0.9),
            ("government.social_security", ["社保", "医保", "公积金", "缴存", "social insurance"], 0.9),
            ("government.court", ["法院", "司法", "立案", "庭审", "执行通知", "court notice"], 0.9),
            ("government.policy", ["政策", "国务院", "新规", "条例", "通告"], 0.85),
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
