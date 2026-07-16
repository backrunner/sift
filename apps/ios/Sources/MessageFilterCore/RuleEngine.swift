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

public enum RuleAction: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case allow
    case block

    public var id: String { rawValue }

    public var systemAction: SystemAction {
        switch self {
        case .allow:
            return .none
        case .block:
            return .junk
        }
    }

    var decisionLabelID: String {
        switch self {
        case .allow:
            return "transaction.message"
        case .block:
            return "spam"
        }
    }
}

public struct CustomRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var priority: Int
    public var sender: SenderMatcher?
    public var text: TextMatcher?
    public var action: RuleAction
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        priority: Int = 0,
        sender: SenderMatcher? = nil,
        text: TextMatcher? = nil,
        action: RuleAction = .block,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.priority = priority
        self.sender = sender
        self.text = text
        self.action = action
        self.createdAt = createdAt
    }

}

public struct RuleMatch: Hashable, Sendable {
    public let rule: CustomRule

    public init(rule: CustomRule) {
        self.rule = rule
    }
}

public struct RuleEngine: Sendable {
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
            return RuleMatch(rule: rule)
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
