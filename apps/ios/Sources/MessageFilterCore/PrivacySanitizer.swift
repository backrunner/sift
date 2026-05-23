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

public struct PrivacySanitizer {
    public init() {}

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
                    redactions.append(Redaction(token: "{{PHONE}}", range: range))
                case .link:
                    redactions.append(Redaction(token: "{{URL}}", range: range))
                default:
                    break
                }
            }
        }

        redactions.append(contentsOf: regexRedactions(in: text, pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, token: "{{EMAIL}}"))
        redactions.append(contentsOf: regexRedactions(in: text, pattern: #"(?:收件地址|地址)[:：]?\s*[^，。；\n]{4,}"#, token: "{{ADDRESS}}"))
        redactions.append(contentsOf: regexRedactions(in: text, pattern: #"(?<!\d)\d{4,8}(?!\d)"#, token: "{{CODE}}"))
        redactions.append(contentsOf: regexRedactions(in: text, pattern: #"(?:¥|￥|RMB|CNY)\s*\d+(?:\.\d{1,2})?|\b\d+(?:\.\d{1,2})?\s*(?:元|块)\b"#, token: "{{AMOUNT}}"))
        redactions.append(contentsOf: regexRedactions(in: text, pattern: #"(订单号|运单号|单号|流水号|取件码|验证码)[:：]?\s*[A-Z0-9-]{4,}"#, token: "{{ORDER_ID}}"))
        redactions.append(contentsOf: regexRedactions(in: text, pattern: #"(?:\d[ -]?){12,19}"#, token: "{{CARD}}"))

        #if canImport(NaturalLanguage)
        redactions.append(contentsOf: nameRedactions(in: text))
        #endif

        return mergeRedactions(redactions, in: text)
    }

    private func regexRedactions(in text: String, pattern: String, token: String) -> [Redaction] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        var redactions: [Redaction] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let stringRange = Range(match.range, in: text) else { return }
            redactions.append(Redaction(token: token, range: stringRange))
        }
        return redactions
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
            guard let tag, tag == .personalName || tag == .organizationName || tag == .placeName else {
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
        let priority = ["{{PHONE}}", "{{URL}}", "{{EMAIL}}", "{{ADDRESS}}", "{{CARD}}", "{{ORDER_ID}}", "{{AMOUNT}}", "{{CODE}}", "{{NAME}}"]
        for token in priority where token == lhs || token == rhs {
            return token
        }
        return lhs
    }

    private func overlaps(existing: [Redaction], candidate: Redaction) -> Bool {
        existing.contains { $0.range.overlaps(candidate.range) }
    }
}
