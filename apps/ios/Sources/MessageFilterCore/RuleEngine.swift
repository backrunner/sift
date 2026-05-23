import Foundation

public struct SenderMatcher: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case exact
        case prefix
        case substring
        case regex
    }

    public var kind: Kind
    public var pattern: String

    public init(kind: Kind, pattern: String) {
        self.kind = kind
        self.pattern = pattern
    }
}

public struct TextMatcher: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case keyword
        case substring
        case regex
    }

    public var kind: Kind
    public var pattern: String

    public init(kind: Kind, pattern: String) {
        self.kind = kind
        self.pattern = pattern
    }
}

public struct CustomRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var priority: Int
    public var sender: SenderMatcher?
    public var text: TextMatcher?
    public var targetLabelID: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        priority: Int = 0,
        sender: SenderMatcher? = nil,
        text: TextMatcher? = nil,
        targetLabelID: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.priority = priority
        self.sender = sender
        self.text = text
        self.targetLabelID = targetLabelID
        self.createdAt = createdAt
    }
}

public struct RuleMatch: Hashable, Sendable {
    public let rule: CustomRule
    public let label: LeafLabel

    public init(rule: CustomRule, label: LeafLabel) {
        self.rule = rule
        self.label = label
    }
}

public struct RuleEngine {
    public init() {}

    public func match(sender: String?, body: String, rules: [CustomRule]) -> RuleMatch? {
        let normalizedSender = normalizeSender(sender ?? "")
        let sorted = rules
            .filter { $0.enabled }
            .sorted { left, right in
                if left.priority != right.priority { return left.priority > right.priority }
                return left.createdAt < right.createdAt
            }

        for rule in sorted {
            guard ruleMatches(rule, sender: normalizedSender, originalSender: sender ?? "", body: body) else {
                continue
            }
            guard let label = SiftTaxonomy.leaf(id: rule.targetLabelID) else {
                continue
            }
            return RuleMatch(rule: rule, label: label)
        }

        return nil
    }

    private func ruleMatches(_ rule: CustomRule, sender: String, originalSender: String, body: String) -> Bool {
        if let senderMatcher = rule.sender, !matchesSender(senderMatcher, sender: sender, originalSender: originalSender) {
            return false
        }
        if let textMatcher = rule.text, !matchesText(textMatcher, body: body) {
            return false
        }
        return rule.sender != nil || rule.text != nil
    }

    private func matchesSender(_ matcher: SenderMatcher, sender: String, originalSender: String) -> Bool {
        switch matcher.kind {
        case .exact:
            return normalizeSender(matcher.pattern) == sender
        case .prefix:
            return sender.hasPrefix(normalizeSender(matcher.pattern))
        case .substring:
            return originalSender.localizedCaseInsensitiveContains(matcher.pattern)
                || sender.localizedCaseInsensitiveContains(normalizeSender(matcher.pattern))
        case .regex:
            return regexMatch(pattern: matcher.pattern, in: originalSender)
        }
    }

    private func matchesText(_ matcher: TextMatcher, body: String) -> Bool {
        switch matcher.kind {
        case .keyword, .substring:
            return body.localizedCaseInsensitiveContains(matcher.pattern)
        case .regex:
            return regexMatch(pattern: matcher.pattern, in: body)
        }
    }

    private func regexMatch(pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private func normalizeSender(_ sender: String) -> String {
        sender
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}
