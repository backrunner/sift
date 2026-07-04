import Foundation

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
        let rules: [(labelID: String, keywords: [String], confidence: Double)] = [
            ("verification", ["验证码", "动态码", "校验码", "verification code", "security code", "otp", "passcode", "認証コード", "確認コード", "ワンタイム"], 0.99),
            ("spam", ["退订", "回复t", "推广", "营销", "广告", "you won", "winner", "claim your prize", "your account will be", "恭喜您"], 0.95),
            ("promotion", ["优惠", "限时", "活动", "折扣", "领券", "促销", "% off", "flash sale", "discount", "voucher", "reply stop"], 0.94),
            ("finance.refund", ["退款", "退回", "原路返回", "refund"], 0.96),
            ("finance.income", ["工资到账", "转账到账", "代发", "存入现金", "收到转账", "salary", "deposited"], 0.93),
            ("finance.bank", ["银行", "账户", "余额", "转账", "扣款", "debited", "credited", "balance"], 0.82),
            ("finance.credit_card", ["信用卡", "账单", "还款", "最低还款", "credit card", "statement", "payment due"], 0.88),
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
            ("carrier.promotion", ["优惠", "专享", "推荐"], 0.78),
            ("government.traffic", ["交警", "12123", "违章", "驾驶证", "etc", "车辆年检", "toll charge"], 0.9),
            ("government.tax", ["税务", "电子税务", "增值税", "个税", "退税", "发票领用", "tax refund"], 0.9),
            ("government.social_security", ["社保", "医保", "公积金", "缴存", "social insurance"], 0.9),
            ("government.court", ["法院", "司法", "立案", "庭审", "执行通知", "court notice"], 0.9),
            ("government.policy", ["政策", "国务院", "新规", "条例", "通告"], 0.85),
            ("government.notice", ["通知", "政务", "公告"], 0.83),
            ("transaction.account_security", ["new device", "sign-in detected", "password was changed"], 0.9)
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
            return ClassificationDecision(
                labelID: match.label.id,
                labelTitle: match.label.title,
                groupID: match.label.groupId,
                groupTitle: match.label.groupTitle,
                confidence: 1,
                systemAction: match.label.systemAction,
                source: .rule
            )
        }

        let decision = classifier.classify(sender: sender, body: body)
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
