import Foundation

public enum SystemAction: String, Codable, Sendable {
    case none
    case transaction
    case promotion
    case junk
}

public struct LeafLabel: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let groupId: String
    public let groupTitle: String
    public let systemAction: SystemAction

    public init(id: String, title: String, groupId: String, groupTitle: String, systemAction: SystemAction) {
        self.id = id
        self.title = title
        self.groupId = groupId
        self.groupTitle = groupTitle
        self.systemAction = systemAction
    }
}

public struct LabelGroup: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemAction: SystemAction
    public let leaves: [LeafLabel]

    public init(id: String, title: String, systemAction: SystemAction, leaves: [LeafLabel]) {
        self.id = id
        self.title = title
        self.systemAction = systemAction
        self.leaves = leaves
    }
}

public enum SiftTaxonomy {
    public static let groups: [LabelGroup] = [
        .init(
            id: "finance",
            title: "财务",
            systemAction: .transaction,
            leaves: [
                .init(id: "finance.bank", title: "银行", groupId: "finance", groupTitle: "财务", systemAction: .transaction),
                .init(id: "finance.insurance", title: "保险", groupId: "finance", groupTitle: "财务", systemAction: .transaction),
                .init(id: "finance.wealth", title: "理财", groupId: "finance", groupTitle: "财务", systemAction: .transaction),
                .init(id: "finance.credit_card", title: "信用卡", groupId: "finance", groupTitle: "财务", systemAction: .transaction),
                .init(id: "finance.consumption", title: "消费", groupId: "finance", groupTitle: "财务", systemAction: .transaction),
                .init(id: "finance.income", title: "入账", groupId: "finance", groupTitle: "财务", systemAction: .transaction),
                .init(id: "finance.refund", title: "退款", groupId: "finance", groupTitle: "财务", systemAction: .transaction),
                .init(id: "finance.stock", title: "股票", groupId: "finance", groupTitle: "财务", systemAction: .transaction),
                .init(id: "finance.other", title: "其他", groupId: "finance", groupTitle: "财务", systemAction: .transaction)
            ]
        ),
        .init(
            id: "transaction",
            title: "交易",
            systemAction: .transaction,
            leaves: [
                .init(id: "transaction.order", title: "订单", groupId: "transaction", groupTitle: "交易", systemAction: .transaction),
                .init(id: "transaction.points", title: "积分", groupId: "transaction", groupTitle: "交易", systemAction: .transaction),
                .init(id: "transaction.member", title: "会员", groupId: "transaction", groupTitle: "交易", systemAction: .transaction),
                .init(id: "transaction.message", title: "消息", groupId: "transaction", groupTitle: "交易", systemAction: .transaction),
                .init(id: "transaction.account_security", title: "账号安全", groupId: "transaction", groupTitle: "交易", systemAction: .transaction),
                .init(id: "transaction.other", title: "其他", groupId: "transaction", groupTitle: "交易", systemAction: .transaction)
            ]
        ),
        .init(
            id: "life",
            title: "生活",
            systemAction: .transaction,
            leaves: [
                .init(id: "life.takeaway", title: "外卖", groupId: "life", groupTitle: "生活", systemAction: .transaction),
                .init(id: "life.express", title: "快递", groupId: "life", groupTitle: "生活", systemAction: .transaction),
                .init(id: "life.utility", title: "生活费用", groupId: "life", groupTitle: "生活", systemAction: .transaction),
                .init(id: "life.logistics", title: "物流", groupId: "life", groupTitle: "生活", systemAction: .transaction),
                .init(id: "life.pickup_code", title: "取件码", groupId: "life", groupTitle: "生活", systemAction: .transaction),
                .init(id: "life.medical", title: "医疗", groupId: "life", groupTitle: "生活", systemAction: .transaction),
                .init(id: "life.weather", title: "天气", groupId: "life", groupTitle: "生活", systemAction: .transaction),
                .init(id: "life.other", title: "其他", groupId: "life", groupTitle: "生活", systemAction: .transaction)
            ]
        ),
        .init(
            id: "travel",
            title: "出行",
            systemAction: .transaction,
            leaves: [
                .init(id: "travel.tourism", title: "旅游", groupId: "travel", groupTitle: "出行", systemAction: .transaction),
                .init(id: "travel.transport", title: "交通", groupId: "travel", groupTitle: "出行", systemAction: .transaction),
                .init(id: "travel.ticketing", title: "票务", groupId: "travel", groupTitle: "出行", systemAction: .transaction),
                .init(id: "travel.other", title: "其他", groupId: "travel", groupTitle: "出行", systemAction: .transaction)
            ]
        ),
        .init(
            id: "work",
            title: "工作",
            systemAction: .transaction,
            leaves: [
                .init(id: "work.meeting", title: "会议", groupId: "work", groupTitle: "工作", systemAction: .transaction),
                .init(id: "work.approval", title: "审批", groupId: "work", groupTitle: "工作", systemAction: .transaction),
                .init(id: "work.attendance", title: "考勤", groupId: "work", groupTitle: "工作", systemAction: .transaction),
                .init(id: "work.announcement", title: "公告", groupId: "work", groupTitle: "工作", systemAction: .transaction),
                .init(id: "work.training", title: "培训", groupId: "work", groupTitle: "工作", systemAction: .transaction),
                .init(id: "work.reminder", title: "提醒", groupId: "work", groupTitle: "工作", systemAction: .transaction),
                .init(id: "work.alert", title: "告警", groupId: "work", groupTitle: "工作", systemAction: .transaction),
                .init(id: "work.other", title: "其他", groupId: "work", groupTitle: "工作", systemAction: .transaction)
            ]
        ),
        .init(
            id: "carrier",
            title: "运营商",
            systemAction: .transaction,
            leaves: [
                .init(id: "carrier.call_reminder", title: "来电提醒", groupId: "carrier", groupTitle: "运营商", systemAction: .transaction),
                .init(id: "carrier.data_reminder", title: "流量提醒", groupId: "carrier", groupTitle: "运营商", systemAction: .transaction),
                .init(id: "carrier.service", title: "业务办理", groupId: "carrier", groupTitle: "运营商", systemAction: .transaction),
                .init(id: "carrier.promotion", title: "推广", groupId: "carrier", groupTitle: "运营商", systemAction: .transaction),
                .init(id: "carrier.other", title: "其他", groupId: "carrier", groupTitle: "运营商", systemAction: .transaction)
            ]
        ),
        .init(
            id: "government",
            title: "政府",
            systemAction: .transaction,
            leaves: [
                .init(id: "government.notice", title: "通知", groupId: "government", groupTitle: "政府", systemAction: .transaction),
                .init(id: "government.traffic", title: "交管", groupId: "government", groupTitle: "政府", systemAction: .transaction),
                .init(id: "government.tax", title: "税务", groupId: "government", groupTitle: "政府", systemAction: .transaction),
                .init(id: "government.social_security", title: "社保医保", groupId: "government", groupTitle: "政府", systemAction: .transaction),
                .init(id: "government.court", title: "司法", groupId: "government", groupTitle: "政府", systemAction: .transaction),
                .init(id: "government.policy", title: "政策", groupId: "government", groupTitle: "政府", systemAction: .transaction),
                .init(id: "government.other", title: "其他", groupId: "government", groupTitle: "政府", systemAction: .transaction)
            ]
        ),
        .init(
            id: "verification",
            title: "验证码",
            systemAction: .transaction,
            leaves: [
                .init(id: "verification", title: "验证码", groupId: "verification", groupTitle: "验证码", systemAction: .transaction)
            ]
        ),
        .init(
            id: "promotion",
            title: "推广信息",
            systemAction: .promotion,
            leaves: [
                .init(id: "promotion", title: "推广信息", groupId: "promotion", groupTitle: "推广信息", systemAction: .promotion)
            ]
        ),
        .init(
            id: "spam",
            title: "垃圾信息",
            systemAction: .junk,
            leaves: [
                .init(id: "spam", title: "垃圾信息", groupId: "spam", groupTitle: "垃圾信息", systemAction: .junk)
            ]
        )
    ]

    public static let leaves: [LeafLabel] = groups.flatMap(\.leaves)
    public static let leafLookup: [String: LeafLabel] = Dictionary(uniqueKeysWithValues: leaves.map { ($0.id, $0) })

    public static func leaf(id: String) -> LeafLabel? {
        leafLookup[id]
    }

    public static func group(id: String) -> LabelGroup? {
        groups.first(where: { $0.id == id })
    }
}

