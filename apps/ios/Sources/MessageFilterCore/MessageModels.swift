import Foundation

public enum ClassificationSource: String, Codable, Sendable {
    case rule
    case model
    case personalization
    case fallback
}

public struct ClassificationDecision: Codable, Hashable, Sendable {
    public let labelID: String
    public let labelTitle: String
    public let groupID: String
    public let groupTitle: String
    public let confidence: Double
    public let systemAction: SystemAction
    public let source: ClassificationSource

    public init(
        labelID: String,
        labelTitle: String,
        groupID: String,
        groupTitle: String,
        confidence: Double,
        systemAction: SystemAction,
        source: ClassificationSource
    ) {
        self.labelID = labelID
        self.labelTitle = labelTitle
        self.groupID = groupID
        self.groupTitle = groupTitle
        self.confidence = confidence
        self.systemAction = systemAction
        self.source = source
    }
}

public struct MessageDraft: Codable, Hashable, Sendable {
    public let sender: String
    public let body: String

    public init(sender: String, body: String) {
        self.sender = sender
        self.body = body
    }
}

public struct SampleSubmissionDraft: Codable, Hashable, Sendable {
    public let text: String
    public let labelID: String
    public let source: String

    public init(text: String, labelID: String, source: String) {
        self.text = text
        self.labelID = labelID
        self.source = source
    }
}
