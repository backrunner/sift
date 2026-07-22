import Foundation

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

private enum VehiclePlatePatterns {
    static let mainlandChina = #"[京津沪渝冀豫云辽黑湘皖鲁新苏浙赣鄂桂甘晋蒙陕吉闽贵粤青藏川宁琼][A-Z][·•・ \t-]?(?:[DF][A-HJ-NP-Z0-9]{5}|[A-HJ-NP-Z0-9]{5}[DF]|[A-HJ-NP-Z0-9]{4}[挂学警港澳领]|[A-HJ-NP-Z0-9]{5})"#

    static let japaneseJurisdiction = #"(?:札幌|函館|旭川|室蘭|釧路|帯広|北見|青森|八戸|岩手|盛岡|宮城|仙台|秋田|山形|庄内|福島|会津|郡山|いわき|水戸|土浦|つくば|宇都宮|那須|とちぎ|群馬|高崎|前橋|大宮|所沢|川越|熊谷|春日部|越谷|千葉|習志野|袖ヶ浦|野田|柏|成田|市川|船橋|松戸|品川|練馬|足立|八王子|多摩|世田谷|杉並|板橋|江東|葛飾|横浜|川崎|相模|湘南|新潟|長岡|上越|富山|石川|金沢|福井|山梨|富士山|長野|松本|諏訪|岐阜|飛騨|静岡|浜松|沼津|伊豆|名古屋|尾張小牧|三河|岡崎|豊田|一宮|春日井|三重|鈴鹿|伊勢志摩|四日市|滋賀|京都|大阪|なにわ|和泉|堺|神戸|姫路|奈良|飛鳥|和歌山|鳥取|島根|岡山|倉敷|広島|福山|山口|下関|徳島|香川|愛媛|高知|福岡|北九州|久留米|筑豊|佐賀|長崎|佐世保|熊本|大分|宮崎|鹿児島|奄美|沖縄)"#
    static let japaneseKana = #"(?:[あいうえかきくけこさすせそたちつてとなにぬねのはひふほまみむめもやゆよらりるれろをわれ]|[EHKMTY])"#
    static let japaneseSerial = #"(?:\d{1,2}-\d{2}|[・･]{1,3}[ \t]*\d{1,3})"#
    static let japan = "\(japaneseJurisdiction)[ \\t]*\\d{1,3}[ \\t]*\(japaneseKana)[ \\t]*\(japaneseSerial)"

    static let france = #"[A-HJ-NP-TV-Z]{2}-\d{3}-[A-HJ-NP-TV-Z]{2}"#
    static let italy = #"[A-HJ-NPR-TV-Z]{2}[ \t]?\d{3}[ \t]?[A-HJ-NPR-TV-Z]{2}"#
    static let germany = #"[A-Z]{1,3}(?:-[A-Z]{1,2}|[ \t]+[A-Z]{1,2})[ \t]+\d{1,4}"#
    static let spain = #"\d{4}[ \t]?[B-DF-HJ-NPR-TV-Z]{3}"#
    static let unitedKingdom = #"[A-Z]{2}\d{2}[ \t]?[A-Z]{3}"#
    static let netherlands = #"(?:[A-Z]{2}-\d{2}-[A-Z]{2}|\d{2}-[A-Z]{2}-\d{2}|\d{2}-\d{2}-[A-Z]{2}|[A-Z]{2}-[A-Z]{2}-\d{2}|[A-Z]{2}-\d{2}-\d{2}|\d{2}-[A-Z]{2}-[A-Z]{2})"#
    static let portugal = #"(?:[A-Z]{2}-\d{2}-[A-Z]{2}|\d{2}-[A-Z]{2}-\d{2}|\d{2}-\d{2}-[A-Z]{2}|[A-Z]{2}-\d{2}-\d{2})"#
    static let belgium = #"(?:[12]-[A-Z]{3}-\d{3}|[A-Z]{3}-\d{3})"#
    static let switzerland = #"[A-Z]{2}[ \t]+\d{1,6}"#
    static let austria = #"[A-Z]{1,2}[ \t]+\d{1,5}[ \t]+[A-Z]{1,2}"#
    static let ireland = #"\d{2,3}-[A-Z]{1,2}-\d{1,6}"#
    static let sweden = #"[A-Z]{3}[ \t]+\d{2}[A-Z0-9]"#
    static let norway = #"[A-Z]{2}[ \t]+\d{4,5}"#
    static let denmark = #"[A-Z]{2}[ \t]?\d{2}[ \t]?\d{3}"#
    static let finland = #"[A-Z]{2,3}-\d{3}"#
    static let poland = #"[A-Z]{1,3}[ \t]+[A-Z0-9]{4,5}"#
    static let hongKong = #"(?:[A-HJ-NPR-Z]{1,2}[ \t]?[1-9]\d{0,3}|[1-9]\d{0,3})"#
    static let northAmericaSpaced = #"(?=[A-Z0-9 -]{3,9}(?![A-Z0-9-]))(?=[A-Z0-9 -]*\d)[A-Z0-9]{1,4}[ -][A-Z0-9]{1,4}"#
    static let northAmericaCompact = #"(?=[A-Z0-9]{1,8}(?![A-Z0-9]))(?=[A-Z0-9]*\d)[A-Z0-9]{1,8}"#

    static let contextual = [
        france, italy, germany, spain, unitedKingdom, netherlands, portugal,
        belgium, switzerland, austria, ireland, sweden, norway, denmark, finland, poland,
        hongKong, northAmericaSpaced, northAmericaCompact
    ]

    static let genericContext = #"(?:license plate(?: number)?|license tag|vehicle tag|plate number|number plate|vehicle plate|registration mark|vehicle registration(?: number)?|车牌号|車牌號|车辆号牌|車輛號牌|车牌|車牌|号牌|號牌|ナンバープレート|車両番号|自動車登録番号|車両登録番号)"#
}

public struct Redaction: Hashable, Sendable {
    public let token: String
    public let range: Range<String.Index>

    public init(token: String, range: Range<String.Index>) {
        self.token = token
        self.range = range
    }
}

public struct SanitizationResult: Hashable, Sendable {
    public let text: String
    public let redactions: [Redaction]

    public init(text: String, redactions: [Redaction]) {
        self.text = text
        self.redactions = redactions
    }
}

/// Two-track sanitizer: deterministic regex/detector rules are the floor and
/// always run; an optional on-device Core ML PII model (see
/// `PIIDetectorLoader`) widens recall on top. Both tracks' findings are
/// unioned before redaction, so a weak early model can never make results
/// worse than rules-only.
public struct PrivacySanitizer {
    private let modelDetector: (any PIIDetecting)?

    public init(modelDetector: (any PIIDetecting)? = nil) {
        self.modelDetector = modelDetector
    }

    /// Rules plus the bundled Core ML PII model when its artifacts ship in
    /// one of the given bundles; rules-only otherwise.
    public static func withBundledModel(bundles: [Bundle] = [.main]) -> PrivacySanitizer {
        PrivacySanitizer(modelDetector: PIIDetectorLoader.bundled(bundles: bundles))
    }

    public func sanitize(_ text: String) -> SanitizationResult {
        let redactions = collectRedactions(in: text).sorted { $0.range.lowerBound < $1.range.lowerBound }
        guard !redactions.isEmpty else {
            return SanitizationResult(text: text, redactions: [])
        }

        var output = text
        var applied: [Redaction] = []

        for redaction in redactions.reversed() {
            guard !overlaps(existing: applied, candidate: redaction) else {
                continue
            }
            output.replaceSubrange(redaction.range, with: redaction.token)
            applied.append(redaction)
        }

        return SanitizationResult(text: output, redactions: applied.reversed())
    }

    private func collectRedactions(in text: String) -> [Redaction] {
        var redactions: [Redaction] = []
        let wholeRange = NSRange(text.startIndex..., in: text)

        let detectorTypes: NSTextCheckingResult.CheckingType = [.link, .phoneNumber]
        if let detector = try? NSDataDetector(types: detectorTypes.rawValue) {
            detector.enumerateMatches(in: text, options: [], range: wholeRange) { match, _, _ in
                guard let match, let range = Range(match.range, in: text) else { return }
                switch match.resultType {
                case .phoneNumber:
                    if isPlausiblePhone(String(text[range]), range: range, in: text) {
                        redactions.append(Redaction(token: "{{PHONE}}", range: range))
                    }
                case .link:
                    redactions.append(Redaction(token: "{{URL}}", range: range))
                default:
                    break
                }
            }
        }

        redactions.append(contentsOf: regexRedactions(in: text, pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, token: "{{EMAIL}}"))
        // 中国居民身份证：18 位（含尾部校验位 X）与 15 位旧式，均要求出生日期段合法。
        redactions.append(contentsOf: regexRedactions(
            in: text,
            pattern: #"(?<![0-9Xx])\d{6}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:[0-2]\d|3[01])\d{3}[\dXx](?![0-9Xx])"#,
            token: "{{ID}}"
        ))
        redactions.append(contentsOf: regexRedactions(
            in: text,
            pattern: #"(?<!\d)\d{6}\d{2}(?:0[1-9]|1[0-2])(?:[0-2]\d|3[01])\d{3}(?!\d)"#,
            token: "{{ID}}"
        ))
        // 中国护照：E/G 开头 + 8 位数字（新版 E 后可带一位字母）。
        redactions.append(contentsOf: regexRedactions(
            in: text,
            pattern: #"\b[EG][A-Z]?\d{8}\b"#,
            token: "{{ID}}"
        ))
        redactions.append(contentsOf: regexRedactions(
            in: text,
            pattern: #"(?:收件地址|配送地址|联系地址|住所|お届け先|delivery address|shipping address)[:：]?\s*([^，。；;\n]{4,})"#,
            token: "{{ADDRESS}}",
            captureGroup: 1
        ))
        redactions.append(contentsOf: regexRedactions(
            in: text,
            pattern: AmountPatterns.amount,
            token: "{{AMOUNT}}"
        ))
        redactions.append(contentsOf: regexRedactions(
            in: text,
            pattern: #"(?:验证码|校验码|动态码|安全码|确认码|認証コード|確認コード|ワンタイムパスワード|verification code|security code|one[- ]time (?:code|password)|otp|passcode)\s*(?:是|为|：|:|is|は)?\s*([A-Z0-9-]{4,10})"#,
            token: "{{CODE}}",
            captureGroup: 1
        ))
        redactions.append(contentsOf: regexRedactions(
            in: text,
            pattern: #"(?:订单号|运单号|快递单号|流水号|取件码|注文番号|追跡番号|order(?: id| number)?|tracking(?: id| number)?)\s*(?:是|为|：|:|#)?\s*([A-Z0-9-]{4,24})"#,
            token: "{{ORDER_ID}}",
            captureGroup: 1
        ))
        redactions.append(contentsOf: plateRedactions(in: text))
        redactions.append(contentsOf: cardRedactions(in: text))

        #if canImport(NaturalLanguage)
        redactions.append(contentsOf: nameRedactions(in: text))
        #endif

        if let modelDetector {
            redactions.append(contentsOf: modelDetector.detections(in: text).compactMap { detection in
                guard shouldAcceptModelDetection(detection, in: text) else { return nil }
                return Redaction(token: detection.kind.token, range: detection.range)
            })
        }

        return mergeRedactions(redactions, in: text)
    }

    private func regexRedactions(
        in text: String,
        pattern: String,
        token: String,
        captureGroup: Int = 0,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> [Redaction] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        var redactions: [Redaction] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard
                let match,
                captureGroup < match.numberOfRanges,
                let stringRange = Range(match.range(at: captureGroup), in: text)
            else { return }
            redactions.append(Redaction(token: token, range: stringRange))
        }
        return redactions
    }

    private func plateRedactions(in text: String) -> [Redaction] {
        var redactions = regexRedactions(
            in: text,
            pattern: "(?<![A-Z0-9])\(VehiclePlatePatterns.mainlandChina)(?![A-Z0-9])",
            token: "{{PLATE}}"
        ).filter { shouldAcceptStrongPlate(at: $0.range, in: text) }
        redactions.append(contentsOf: regexRedactions(
            in: text,
            pattern: "(?<![\\u3400-\\u9FFF])\(VehiclePlatePatterns.japan)(?![0-9A-Z])",
            token: "{{PLATE}}"
        ).filter { shouldAcceptStrongPlate(at: $0.range, in: text) })
        redactions.append(contentsOf: contextualPlateRedactions(
            in: text,
            contextPattern: VehiclePlatePatterns.genericContext,
            candidatePatterns: [VehiclePlatePatterns.japan] + VehiclePlatePatterns.contextual
        ))
        redactions.append(contentsOf: contextualPlateRedactions(
            in: text,
            contextPattern: #"(?:plaque d'immatriculation|immatriculation du véhicule)"#,
            candidatePatterns: [VehiclePlatePatterns.france, VehiclePlatePatterns.belgium]
        ))
        redactions.append(contentsOf: contextualPlateRedactions(
            in: text,
            contextPattern: #"(?:kfz-kennzeichen|autokennzeichen|kennzeichen des fahrzeugs)"#,
            candidatePatterns: [
                VehiclePlatePatterns.germany,
                VehiclePlatePatterns.austria,
                VehiclePlatePatterns.switzerland
            ]
        ))
        redactions.append(contentsOf: contextualPlateRedactions(
            in: text,
            contextPattern: #"targa"#,
            candidatePatterns: [VehiclePlatePatterns.italy]
        ))
        redactions.append(contentsOf: contextualPlateRedactions(
            in: text,
            contextPattern: #"(?:matr[ií]cula del (?:veh[ií]culo|coche)|placa vehicular)"#,
            candidatePatterns: [VehiclePlatePatterns.spain]
        ))
        redactions.append(contentsOf: contextualPlateRedactions(
            in: text,
            contextPattern: #"(?:matr[ií]cula do (?:ve[ií]culo|automóvel)|chapa de matr[ií]cula)"#,
            candidatePatterns: [VehiclePlatePatterns.portugal]
        ))
        redactions.append(contentsOf: contextualPlateRedactions(
            in: text,
            contextPattern: #"kenteken"#,
            candidatePatterns: [VehiclePlatePatterns.netherlands, VehiclePlatePatterns.belgium]
        ))
        redactions.append(contentsOf: contextualPlateRedactions(
            in: text,
            contextPattern: #"(?:fordonets|kjøretøyets) registreringsnummer"#,
            candidatePatterns: [VehiclePlatePatterns.sweden, VehiclePlatePatterns.norway]
        ))
        redactions.append(contentsOf: contextualPlateRedactions(
            in: text,
            contextPattern: #"(?:nummerplade|køretøjets registreringsnummer)"#,
            candidatePatterns: [VehiclePlatePatterns.denmark]
        ))
        redactions.append(contentsOf: contextualPlateRedactions(
            in: text,
            contextPattern: #"(?:ajoneuvon rekisteritunnus|rekisterikilpi)"#,
            candidatePatterns: [VehiclePlatePatterns.finland]
        ))
        redactions.append(contentsOf: contextualPlateRedactions(
            in: text,
            contextPattern: #"(?:numer rejestracyjny pojazdu|tablica rejestracyjna)"#,
            candidatePatterns: [VehiclePlatePatterns.poland]
        ))
        return redactions
    }

    private func contextualPlateRedactions(
        in text: String,
        contextPattern: String,
        candidatePatterns: [String]
    ) -> [Redaction] {
        let candidates = candidatePatterns.joined(separator: "|")
        return regexRedactions(
            in: text,
            pattern: "\(contextPattern)[ \\t]*(?:is|是|为|は|：|:|#)?[ \\t]*(\(candidates))(?![A-Z0-9-])",
            token: "{{PLATE}}",
            captureGroup: 1
        ).filter { shouldAcceptContextualPlate($0, in: text) }
    }

    private func shouldAcceptContextualPlate(_ redaction: Redaction, in text: String) -> Bool {
        let context = "\(platePrefixContext(before: redaction.range, in: text)) \(plateSuffixContext(after: redaction.range, in: text))"
        let value = String(text[redaction.range])
        let regionalRestrictions: [([String], [String])] = [
            (["香港", "hong kong"], [VehiclePlatePatterns.hongKong]),
            (["日本", "japan", "japanese"], [VehiclePlatePatterns.japan]),
            (["中国", "中國", "内地", "內地", "大陆", "大陸", "mainland china"], [VehiclePlatePatterns.mainlandChina]),
            (["france", "french"], [VehiclePlatePatterns.france]),
            (["germany", "german"], [VehiclePlatePatterns.germany]),
            (["italy", "italian"], [VehiclePlatePatterns.italy]),
            (["spain", "spanish"], [VehiclePlatePatterns.spain]),
            (["united kingdom", "british"], [VehiclePlatePatterns.unitedKingdom]),
            (["netherlands", "dutch"], [VehiclePlatePatterns.netherlands]),
            (["portugal", "portuguese"], [VehiclePlatePatterns.portugal]),
            (["belgium", "belgian"], [VehiclePlatePatterns.belgium]),
            (["switzerland", "swiss"], [VehiclePlatePatterns.switzerland]),
            (["austria", "austrian"], [VehiclePlatePatterns.austria]),
            (["ireland", "irish"], [VehiclePlatePatterns.ireland]),
            (["sweden", "swedish"], [VehiclePlatePatterns.sweden]),
            (["norway", "norwegian"], [VehiclePlatePatterns.norway]),
            (["denmark", "danish"], [VehiclePlatePatterns.denmark]),
            (["finland", "finnish"], [VehiclePlatePatterns.finland]),
            (["poland", "polish"], [VehiclePlatePatterns.poland]),
            (["united states", "american", "usa"], [
                VehiclePlatePatterns.northAmericaSpaced,
                VehiclePlatePatterns.northAmericaCompact
            ])
        ]
        for (keywords, patterns) in regionalRestrictions where keywords.contains(where: context.contains) {
            return patterns.contains { matchesWholePattern(value, pattern: $0) }
        }
        return true
    }

    private func matchesWholePattern(_ value: String, pattern: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        guard let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$", options: [.caseInsensitive]) else {
            return false
        }
        return regex.firstMatch(in: value, range: range)?.range == range
    }

    private func cardRedactions(in text: String) -> [Redaction] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)(?:\d[ -]?){15,18}\d(?!\d)"#) else {
            return []
        }
        let wholeRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: wholeRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let value = String(text[range])
            guard isPlausibleCard(value, range: range, in: text) else { return nil }
            return Redaction(token: "{{CARD}}", range: range)
        }
    }

    private func shouldAcceptModelDetection(_ detection: PIIDetection, in text: String) -> Bool {
        switch detection.kind {
        case .card:
            return isPlausibleCard(String(text[detection.range]), range: detection.range, in: text)
        case .code:
            return isPlausibleCode(String(text[detection.range]), range: detection.range, in: text)
        case .orderID:
            return isPlausibleOrderID(String(text[detection.range]), range: detection.range, in: text)
        case .phone:
            return isPlausiblePhone(String(text[detection.range]), range: detection.range, in: text)
        case .amount:
            return isPlausibleAmount(String(text[detection.range]), range: detection.range, in: text)
        default:
            return true
        }
    }

    private func isPlausibleAmount(_ value: String, range: Range<String.Index>, in text: String) -> Bool {
        guard value.contains(where: \.isNumber) else { return false }

        let lower = text.index(range.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 16, limitedBy: text.endIndex) ?? text.endIndex
        let context = text[lower..<upper].lowercased()
        let currencyMarkers = ["¥", "￥", "$", "€", "£", "rmb", "cny", "usd", "eur", "gbp", "jpy", "元", "块", "円"]
        let tightLower = text.index(range.lowerBound, offsetBy: -6, limitedBy: text.startIndex) ?? text.startIndex
        let tightUpper = text.index(range.upperBound, offsetBy: 6, limitedBy: text.endIndex) ?? text.endIndex
        let tightContext = text[tightLower..<tightUpper].lowercased()

        let nonAmountMarkers = [
            "积分", "得分", "参与者", "参加者", "人数",
            "points", "score", "participants", "attendees", "views", "steps",
            "ポイント", "スコア", "参加者"
        ]
        if nonAmountMarkers.contains(where: context.contains) {
            return false
        }

        let suffix = text[range.upperBound..<upper]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["名", "人", "件", "步", "歩", "分", "points", "participants", "attendees", "views", "steps"]
            .contains(where: suffix.hasPrefix)
        {
            return false
        }

        if currencyMarkers.contains(where: tightContext.contains) {
            return true
        }

        return [
            "金额", "金額", "价格", "價格", "价款", "價款", "支付", "付款", "应还", "應還",
            "实付", "實付", "到账", "到賬", "入账", "入賬", "账单", "帳單", "合计", "合計",
            "amount", "price", "total", "payment", "paid", "charged", "charge", "due", "cost",
            "料金", "価格", "支払", "請求", "合計", "入金"
        ].contains(where: context.contains)
    }

    private func isPlausibleCode(_ value: String, range: Range<String.Index>, in text: String) -> Bool {
        let compact = value.filter { !$0.isWhitespace }
        guard (4...10).contains(compact.count), compact.contains(where: \.isNumber) else {
            return false
        }
        guard compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return false
        }
        return hasCodeContext(around: range, in: text)
    }

    private func hasCodeContext(around range: Range<String.Index>, in text: String) -> Bool {
        let lower = text.index(range.lowerBound, offsetBy: -32, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 16, limitedBy: text.endIndex) ?? text.endIndex
        let context = text[lower..<upper].lowercased()
        return [
            "验证码", "校验码", "动态码", "安全码", "确认码", "一次性密码", "一次性口令",
            "認証コード", "確認コード", "ワンタイムパスワード",
            "verification code", "security code", "one-time code", "one time code",
            "one-time password", "one time password", "otp", "passcode"
        ].contains { context.contains($0) }
    }

    private func isPlausibleOrderID(_ value: String, range: Range<String.Index>, in text: String) -> Bool {
        let compact = value.filter { !$0.isWhitespace }
        guard
            (4...24).contains(compact.count),
            compact.contains(where: \.isNumber),
            compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else {
            return false
        }
        let lower = text.index(range.lowerBound, offsetBy: -32, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 16, limitedBy: text.endIndex) ?? text.endIndex
        let context = text[lower..<upper].lowercased()
        return [
            "订单号", "订单编号", "运单号", "快递单号", "流水号", "取件码",
            "注文番号", "追跡番号", "予約番号",
            "order id", "order number", "tracking id", "tracking number", "reservation number"
        ].contains(where: context.contains)
    }

    private func isPlausiblePhone(_ value: String, range: Range<String.Index>, in text: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard (7...15).contains(digits.count) else { return false }
        if value.contains("+") || hasPhoneContext(around: range, in: text) {
            return true
        }
        guard digits.count == 11, digits.first == 1 else { return false }
        return (3...9).contains(digits[1])
    }

    private func shouldAcceptStrongPlate(at range: Range<String.Index>, in text: String) -> Bool {
        let context = platePrefixContext(before: range, in: text)
        return !containsConflictingPlateKeyword(context)
            && !containsConflictingPlateKeyword(plateSuffixContext(after: range, in: text))
    }

    private func containsConflictingPlateKeyword(_ context: String) -> Bool {
        [
            "航班", "车次", "订单", "产品型号", "商品代码", "活动编号", "构建编号",
            "flight", "train number", "order", "product model", "product code", "campaign", "build",
            "予約番号", "注文番号", "便名", "製品型番", "商品コード", "企画番号", "ビルド番号"
        ].contains(where: context.contains)
    }

    private func platePrefixContext(before range: Range<String.Index>, in text: String) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let context = text[lower..<range.lowerBound].lowercased()
        let separators: Set<Character> = [",", "，", ".", "。", "!", "！", "?", "？", ";", "；", "\n", "\r"]
        guard let separator = context.lastIndex(where: separators.contains) else {
            return context
        }
        return String(context[context.index(after: separator)...])
    }

    private func plateSuffixContext(after range: Range<String.Index>, in text: String) -> String {
        let upper = text.index(range.upperBound, offsetBy: 32, limitedBy: text.endIndex) ?? text.endIndex
        let context = text[range.upperBound..<upper].lowercased()
        let separators: Set<Character> = [",", "，", ".", "。", "!", "！", "?", "？", ";", "；", "\n", "\r"]
        guard let separator = context.firstIndex(where: separators.contains) else {
            return context
        }
        return String(context[..<separator])
    }

    private func hasPhoneContext(around range: Range<String.Index>, in text: String) -> Bool {
        let lower = text.index(range.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
        let context = text[lower..<upper].lowercased()
        return ["联系电话", "手机号", "手机号码", "电话", "拨打", "致电", "tel", "phone", "call", "電話", "連絡先", "連絡"]
            .contains { context.contains($0) }
    }

    private func isPlausibleCard(_ value: String, range: Range<String.Index>, in text: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard (16...19).contains(digits.count) else { return false }
        return passesLuhn(digits) || hasCardContext(around: range, in: text)
    }

    private func hasCardContext(around range: Range<String.Index>, in text: String) -> Bool {
        let lower = text.index(range.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
        let context = text[lower..<upper].lowercased()
        return ["银行卡", "信用卡", "卡号", "bank card", "card number", "カード番号", "クレジットカード"]
            .contains { context.contains($0) }
    }

    private func passesLuhn(_ digits: [Int]) -> Bool {
        var sum = 0
        let parity = digits.count % 2
        for (index, digit) in digits.enumerated() {
            var value = digit
            if index % 2 == parity {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }

    #if canImport(NaturalLanguage)
    private func nameRedactions(in text: String) -> [Redaction] {
        let tokenizer = NLTagger(tagSchemes: [.nameType])
        tokenizer.string = text
        var redactions: [Redaction] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        tokenizer.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            guard let tag, tag == .personalName else {
                return true
            }
            redactions.append(Redaction(token: "{{NAME}}", range: range))
            return true
        }

        return redactions
    }
    #endif

    private func mergeRedactions(_ redactions: [Redaction], in text: String) -> [Redaction] {
        guard !redactions.isEmpty else {
            return []
        }

        let sorted = redactions.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var merged: [Redaction] = []
        var current = sorted[0]

        for candidate in sorted.dropFirst() {
            if candidate.range.lowerBound <= current.range.upperBound {
                let upper = max(current.range.upperBound, candidate.range.upperBound)
                current = Redaction(
                    token: chooseToken(current.token, candidate.token),
                    range: current.range.lowerBound..<upper
                )
            } else {
                merged.append(current)
                current = candidate
            }
        }

        merged.append(current)
        return merged
    }

    private func chooseToken(_ lhs: String, _ rhs: String) -> String {
        if lhs == rhs { return lhs }
        let priority = ["{{PHONE}}", "{{URL}}", "{{EMAIL}}", "{{ID}}", "{{PLATE}}", "{{ADDRESS}}", "{{CARD}}", "{{ORDER_ID}}", "{{AMOUNT}}", "{{CODE}}", "{{NAME}}"]
        for token in priority where token == lhs || token == rhs {
            return token
        }
        return lhs
    }

    private func overlaps(existing: [Redaction], candidate: Redaction) -> Bool {
        existing.contains { $0.range.overlaps(candidate.range) }
    }
}
