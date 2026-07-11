import Foundation

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

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
        redactions.append(contentsOf: regexRedactions(in: text, pattern: #"(?:¥|￥|RMB|CNY)\s*\d+(?:\.\d{1,2})?|\b\d+(?:\.\d{1,2})?\s*(?:元|块)\b"#, token: "{{AMOUNT}}"))
        redactions.append(contentsOf: regexRedactions(
            in: text,
            pattern: #"(?:验证码|校验码|动态码|安全码|确认码|認証コード|確認コード|ワンタイムパスワード|verification code|security code|one[- ]time (?:code|password)|otp|passcode)\s*(?:是|为|：|:)?\s*([A-Z0-9-]{4,10})"#,
            token: "{{CODE}}",
            captureGroup: 1
        ))
        redactions.append(contentsOf: regexRedactions(
            in: text,
            pattern: #"(?:订单号|运单号|快递单号|流水号|取件码|注文番号|追跡番号|order(?: id| number)?|tracking(?: id| number)?)\s*(?:是|为|：|:|#)?\s*([A-Z0-9-]{4,24})"#,
            token: "{{ORDER_ID}}",
            captureGroup: 1
        ))
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
        captureGroup: Int = 0
    ) -> [Redaction] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
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
        case .phone:
            return isPlausiblePhone(String(text[detection.range]), range: detection.range, in: text)
        default:
            return true
        }
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

    private func isPlausiblePhone(_ value: String, range: Range<String.Index>, in text: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard (7...15).contains(digits.count) else { return false }
        if value.contains("+") || hasPhoneContext(around: range, in: text) {
            return true
        }
        guard digits.count == 11, digits.first == 1 else { return false }
        return (3...9).contains(digits[1])
    }

    private func hasPhoneContext(around range: Range<String.Index>, in text: String) -> Bool {
        let lower = text.index(range.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
        let context = text[lower..<upper].lowercased()
        return ["联系电话", "手机号", "手机号码", "电话", "拨打", "致电", "tel", "phone", "call", "電話", "連絡先"]
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
        let priority = ["{{PHONE}}", "{{URL}}", "{{EMAIL}}", "{{ID}}", "{{ADDRESS}}", "{{CARD}}", "{{ORDER_ID}}", "{{AMOUNT}}", "{{CODE}}", "{{NAME}}"]
        for token in priority where token == lhs || token == rhs {
            return token
        }
        return lhs
    }

    private func overlaps(existing: [Redaction], candidate: Redaction) -> Bool {
        existing.contains { $0.range.overlaps(candidate.range) }
    }
}
