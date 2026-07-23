import Foundation

public enum SystemAction: String, Codable, Sendable {
    case none
    case transaction
    case promotion
    case junk
}

public struct LeafLabel: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    /// Localized display names keyed by language (zh / en / ja).
    public let titles: [String: String]
    public let groupId: String
    public let groupTitles: [String: String]
    public let systemAction: SystemAction

    public init(id: String, titles: [String: String], groupId: String, groupTitles: [String: String], systemAction: SystemAction) {
        self.id = id
        self.titles = titles
        self.groupId = groupId
        self.groupTitles = groupTitles
        self.systemAction = systemAction
    }

    /// Display name in the user's preferred language (zh fallback).
    public var title: String {
        SiftTaxonomy.localizedTitle(from: titles)
    }

    public var groupTitle: String {
        SiftTaxonomy.localizedTitle(from: groupTitles)
    }
}

public struct LabelGroup: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let titles: [String: String]
    public let systemAction: SystemAction
    public let leaves: [LeafLabel]

    public init(id: String, titles: [String: String], systemAction: SystemAction, leaves: [LeafLabel]) {
        self.id = id
        self.titles = titles
        self.systemAction = systemAction
        self.leaves = leaves
    }

    public var title: String {
        SiftTaxonomy.localizedTitle(from: titles)
    }
}

public enum SiftTaxonomy {
    /// Resolves a titles dictionary against the user's preferred languages
    /// (zh / en / ja supported; Chinese is the base language).
    public static func localizedTitle(
        from titles: [String: String],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        for language in preferredLanguages {
            if language.hasPrefix("zh"), let title = titles["zh"] { return title }
            if language.hasPrefix("ja"), let title = titles["ja"] { return title }
            if language.hasPrefix("en"), let title = titles["en"] { return title }
        }
        return titles["zh"] ?? titles["en"] ?? titles.values.sorted().first ?? ""
    }

    public static let groups: [LabelGroup] = [
        .init(
            id: "finance",
            titles: ["zh": "财务", "en": "Finance", "ja": "金融"],
            systemAction: .transaction,
            leaves: [
                .init(id: "finance.bank", titles: ["zh": "银行", "en": "Banking", "ja": "銀行"], groupId: "finance", groupTitles: ["zh": "财务", "en": "Finance", "ja": "金融"], systemAction: .transaction),
                .init(id: "finance.insurance", titles: ["zh": "保险", "en": "Insurance", "ja": "保険"], groupId: "finance", groupTitles: ["zh": "财务", "en": "Finance", "ja": "金融"], systemAction: .transaction),
                .init(id: "finance.wealth", titles: ["zh": "理财", "en": "Wealth", "ja": "資産運用"], groupId: "finance", groupTitles: ["zh": "财务", "en": "Finance", "ja": "金融"], systemAction: .transaction),
                .init(id: "finance.credit_card", titles: ["zh": "信用卡", "en": "Credit Card", "ja": "クレジットカード"], groupId: "finance", groupTitles: ["zh": "财务", "en": "Finance", "ja": "金融"], systemAction: .transaction),
                .init(id: "finance.consumption", titles: ["zh": "消费", "en": "Purchases", "ja": "支払い"], groupId: "finance", groupTitles: ["zh": "财务", "en": "Finance", "ja": "金融"], systemAction: .transaction),
                .init(id: "finance.income", titles: ["zh": "入账", "en": "Income", "ja": "入金"], groupId: "finance", groupTitles: ["zh": "财务", "en": "Finance", "ja": "金融"], systemAction: .transaction),
                .init(id: "finance.refund", titles: ["zh": "退款", "en": "Refunds", "ja": "返金"], groupId: "finance", groupTitles: ["zh": "财务", "en": "Finance", "ja": "金融"], systemAction: .transaction),
                .init(id: "finance.stock", titles: ["zh": "股票", "en": "Securities", "ja": "証券"], groupId: "finance", groupTitles: ["zh": "财务", "en": "Finance", "ja": "金融"], systemAction: .transaction),
                .init(id: "finance.other", titles: ["zh": "其他", "en": "Other Finance", "ja": "その他（金融）"], groupId: "finance", groupTitles: ["zh": "财务", "en": "Finance", "ja": "金融"], systemAction: .transaction)
            ]
        ),
        .init(
            id: "transaction",
            titles: ["zh": "账户与订单", "en": "Account & Orders", "ja": "アカウントと注文"],
            systemAction: .transaction,
            leaves: [
                .init(id: "transaction.order", titles: ["zh": "订单", "en": "Orders", "ja": "注文"], groupId: "transaction", groupTitles: ["zh": "账户与订单", "en": "Account & Orders", "ja": "アカウントと注文"], systemAction: .transaction),
                .init(id: "transaction.points", titles: ["zh": "积分", "en": "Points", "ja": "ポイント"], groupId: "transaction", groupTitles: ["zh": "账户与订单", "en": "Account & Orders", "ja": "アカウントと注文"], systemAction: .transaction),
                .init(id: "transaction.member", titles: ["zh": "会员", "en": "Membership", "ja": "会員"], groupId: "transaction", groupTitles: ["zh": "账户与订单", "en": "Account & Orders", "ja": "アカウントと注文"], systemAction: .transaction),
                .init(id: "transaction.message", titles: ["zh": "平台消息", "en": "Platform Messages", "ja": "プラットフォーム通知"], groupId: "transaction", groupTitles: ["zh": "账户与订单", "en": "Account & Orders", "ja": "アカウントと注文"], systemAction: .transaction),
                .init(id: "transaction.account_security", titles: ["zh": "账号安全", "en": "Account Security", "ja": "アカウント保護"], groupId: "transaction", groupTitles: ["zh": "账户与订单", "en": "Account & Orders", "ja": "アカウントと注文"], systemAction: .transaction),
                .init(id: "transaction.other", titles: ["zh": "其他", "en": "Other Account", "ja": "その他（アカウント）"], groupId: "transaction", groupTitles: ["zh": "账户与订单", "en": "Account & Orders", "ja": "アカウントと注文"], systemAction: .transaction)
            ]
        ),
        .init(
            id: "life",
            titles: ["zh": "生活", "en": "Daily Life", "ja": "生活"],
            systemAction: .transaction,
            leaves: [
                .init(id: "life.takeaway", titles: ["zh": "外卖", "en": "Food Delivery", "ja": "フードデリバリー"], groupId: "life", groupTitles: ["zh": "生活", "en": "Daily Life", "ja": "生活"], systemAction: .transaction),
                .init(id: "life.express", titles: ["zh": "快递", "en": "Parcels", "ja": "宅配便"], groupId: "life", groupTitles: ["zh": "生活", "en": "Daily Life", "ja": "生活"], systemAction: .transaction),
                .init(id: "life.utility", titles: ["zh": "生活费用", "en": "Utilities", "ja": "公共料金"], groupId: "life", groupTitles: ["zh": "生活", "en": "Daily Life", "ja": "生活"], systemAction: .transaction),
                .init(id: "life.logistics", titles: ["zh": "物流", "en": "Logistics", "ja": "物流"], groupId: "life", groupTitles: ["zh": "生活", "en": "Daily Life", "ja": "生活"], systemAction: .transaction),
                .init(id: "life.pickup_code", titles: ["zh": "取件码", "en": "Pickup Codes", "ja": "受取コード"], groupId: "life", groupTitles: ["zh": "生活", "en": "Daily Life", "ja": "生活"], systemAction: .transaction),
                .init(id: "life.medical", titles: ["zh": "医疗", "en": "Healthcare", "ja": "医療"], groupId: "life", groupTitles: ["zh": "生活", "en": "Daily Life", "ja": "生活"], systemAction: .transaction),
                .init(id: "life.weather", titles: ["zh": "天气", "en": "Weather", "ja": "気象情報"], groupId: "life", groupTitles: ["zh": "生活", "en": "Daily Life", "ja": "生活"], systemAction: .transaction),
                .init(id: "life.other", titles: ["zh": "其他", "en": "Other Life", "ja": "その他（生活）"], groupId: "life", groupTitles: ["zh": "生活", "en": "Daily Life", "ja": "生活"], systemAction: .transaction)
            ]
        ),
        .init(
            id: "travel",
            titles: ["zh": "出行", "en": "Travel", "ja": "旅行・交通"],
            systemAction: .transaction,
            leaves: [
                .init(id: "travel.tourism", titles: ["zh": "旅游", "en": "Tourism", "ja": "観光"], groupId: "travel", groupTitles: ["zh": "出行", "en": "Travel", "ja": "旅行・交通"], systemAction: .transaction),
                .init(id: "travel.transport", titles: ["zh": "交通", "en": "Transport", "ja": "交通"], groupId: "travel", groupTitles: ["zh": "出行", "en": "Travel", "ja": "旅行・交通"], systemAction: .transaction),
                .init(id: "travel.ticketing", titles: ["zh": "票务", "en": "Tickets", "ja": "チケット"], groupId: "travel", groupTitles: ["zh": "出行", "en": "Travel", "ja": "旅行・交通"], systemAction: .transaction),
                .init(id: "travel.other", titles: ["zh": "其他", "en": "Other Travel", "ja": "その他（旅行）"], groupId: "travel", groupTitles: ["zh": "出行", "en": "Travel", "ja": "旅行・交通"], systemAction: .transaction)
            ]
        ),
        .init(
            id: "work",
            titles: ["zh": "工作", "en": "Work", "ja": "仕事"],
            systemAction: .transaction,
            leaves: [
                .init(id: "work.meeting", titles: ["zh": "会议", "en": "Meetings", "ja": "会議"], groupId: "work", groupTitles: ["zh": "工作", "en": "Work", "ja": "仕事"], systemAction: .transaction),
                .init(id: "work.approval", titles: ["zh": "审批", "en": "Approvals", "ja": "承認"], groupId: "work", groupTitles: ["zh": "工作", "en": "Work", "ja": "仕事"], systemAction: .transaction),
                .init(id: "work.attendance", titles: ["zh": "考勤", "en": "Attendance", "ja": "勤怠"], groupId: "work", groupTitles: ["zh": "工作", "en": "Work", "ja": "仕事"], systemAction: .transaction),
                .init(id: "work.announcement", titles: ["zh": "公告", "en": "Announcements", "ja": "社内通知"], groupId: "work", groupTitles: ["zh": "工作", "en": "Work", "ja": "仕事"], systemAction: .transaction),
                .init(id: "work.training", titles: ["zh": "培训", "en": "Training", "ja": "研修"], groupId: "work", groupTitles: ["zh": "工作", "en": "Work", "ja": "仕事"], systemAction: .transaction),
                .init(id: "work.reminder", titles: ["zh": "提醒", "en": "Reminders", "ja": "リマインダー"], groupId: "work", groupTitles: ["zh": "工作", "en": "Work", "ja": "仕事"], systemAction: .transaction),
                .init(id: "work.alert", titles: ["zh": "告警", "en": "Alerts", "ja": "アラート"], groupId: "work", groupTitles: ["zh": "工作", "en": "Work", "ja": "仕事"], systemAction: .transaction),
                .init(id: "work.other", titles: ["zh": "其他", "en": "Other Work", "ja": "その他（仕事）"], groupId: "work", groupTitles: ["zh": "工作", "en": "Work", "ja": "仕事"], systemAction: .transaction)
            ]
        ),
        .init(
            id: "carrier",
            titles: ["zh": "运营商", "en": "Carrier", "ja": "通信キャリア"],
            systemAction: .transaction,
            leaves: [
                .init(id: "carrier.call_reminder", titles: ["zh": "来电提醒", "en": "Missed Calls", "ja": "不在着信"], groupId: "carrier", groupTitles: ["zh": "运营商", "en": "Carrier", "ja": "通信キャリア"], systemAction: .transaction),
                .init(id: "carrier.data_reminder", titles: ["zh": "流量提醒", "en": "Data & Balance", "ja": "データ残量"], groupId: "carrier", groupTitles: ["zh": "运营商", "en": "Carrier", "ja": "通信キャリア"], systemAction: .transaction),
                .init(id: "carrier.billing", titles: ["zh": "账单", "en": "Billing & Payments", "ja": "請求・支払い"], groupId: "carrier", groupTitles: ["zh": "运营商", "en": "Carrier", "ja": "通信キャリア"], systemAction: .transaction),
                .init(id: "carrier.service", titles: ["zh": "业务办理", "en": "Carrier Services", "ja": "契約手続き"], groupId: "carrier", groupTitles: ["zh": "运营商", "en": "Carrier", "ja": "通信キャリア"], systemAction: .transaction),
                .init(id: "carrier.promotion", titles: ["zh": "推广", "en": "Carrier Offers", "ja": "キャリア特典"], groupId: "carrier", groupTitles: ["zh": "运营商", "en": "Carrier", "ja": "通信キャリア"], systemAction: .promotion),
                .init(id: "carrier.other", titles: ["zh": "其他", "en": "Other Carrier", "ja": "その他（キャリア）"], groupId: "carrier", groupTitles: ["zh": "运营商", "en": "Carrier", "ja": "通信キャリア"], systemAction: .transaction)
            ]
        ),
        .init(
            id: "government",
            titles: ["zh": "政务", "en": "Government", "ja": "行政"],
            systemAction: .transaction,
            leaves: [
                .init(id: "government.notice", titles: ["zh": "通知", "en": "Public Notices", "ja": "行政通知"], groupId: "government", groupTitles: ["zh": "政务", "en": "Government", "ja": "行政"], systemAction: .transaction),
                .init(id: "government.traffic", titles: ["zh": "交管", "en": "Traffic Authority", "ja": "交通行政"], groupId: "government", groupTitles: ["zh": "政务", "en": "Government", "ja": "行政"], systemAction: .transaction),
                .init(id: "government.tax", titles: ["zh": "税务", "en": "Tax", "ja": "税務"], groupId: "government", groupTitles: ["zh": "政务", "en": "Government", "ja": "行政"], systemAction: .transaction),
                .init(id: "government.social_security", titles: ["zh": "社保医保", "en": "Social Security", "ja": "社会保障"], groupId: "government", groupTitles: ["zh": "政务", "en": "Government", "ja": "行政"], systemAction: .transaction),
                .init(id: "government.court", titles: ["zh": "司法", "en": "Judicial", "ja": "司法"], groupId: "government", groupTitles: ["zh": "政务", "en": "Government", "ja": "行政"], systemAction: .transaction),
                .init(id: "government.policy", titles: ["zh": "政策", "en": "Policy", "ja": "政策"], groupId: "government", groupTitles: ["zh": "政务", "en": "Government", "ja": "行政"], systemAction: .transaction),
                .init(id: "government.other", titles: ["zh": "其他", "en": "Other Government", "ja": "その他（行政）"], groupId: "government", groupTitles: ["zh": "政务", "en": "Government", "ja": "行政"], systemAction: .transaction)
            ]
        ),
        .init(
            id: "verification",
            titles: ["zh": "验证码", "en": "Verification Codes", "ja": "認証コード"],
            systemAction: .transaction,
            leaves: [
                .init(id: "verification", titles: ["zh": "验证码", "en": "Verification Codes", "ja": "認証コード"], groupId: "verification", groupTitles: ["zh": "验证码", "en": "Verification Codes", "ja": "認証コード"], systemAction: .transaction)
            ]
        ),
        .init(
            id: "promotion",
            titles: ["zh": "推广信息", "en": "Promotions", "ja": "プロモーション"],
            systemAction: .promotion,
            leaves: [
                .init(id: "promotion", titles: ["zh": "推广信息", "en": "Promotions", "ja": "プロモーション"], groupId: "promotion", groupTitles: ["zh": "推广信息", "en": "Promotions", "ja": "プロモーション"], systemAction: .promotion)
            ]
        ),
        .init(
            id: "spam",
            titles: ["zh": "垃圾信息", "en": "Spam & Fraud", "ja": "迷惑・詐欺"],
            systemAction: .junk,
            leaves: [
                .init(id: "spam", titles: ["zh": "垃圾信息", "en": "Spam & Fraud", "ja": "迷惑・詐欺"], groupId: "spam", groupTitles: ["zh": "垃圾信息", "en": "Spam & Fraud", "ja": "迷惑・詐欺"], systemAction: .junk)
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
