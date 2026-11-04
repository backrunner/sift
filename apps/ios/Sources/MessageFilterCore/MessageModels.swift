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
    /// Probability of the default transaction action, never leaf confidence.
    /// Only a validated full transformer distribution may supply this value.
    public let transactionConfidence: Double?
    public let systemAction: SystemAction
    public let source: ClassificationSource
    public let categoryMappingTarget: CategoryMappingTarget?

    public init(
        labelID: String,
        labelTitle: String,
        groupID: String,
        groupTitle: String,
        confidence: Double,
        systemAction: SystemAction,
        source: ClassificationSource,
        categoryMappingTarget: CategoryMappingTarget? = nil,
        transactionConfidence: Double? = nil
    ) {
        self.labelID = labelID
        self.labelTitle = labelTitle
        self.groupID = groupID
        self.groupTitle = groupTitle
        self.confidence = confidence
        self.transactionConfidence = transactionConfidence
        self.systemAction = systemAction
        self.source = source
        self.categoryMappingTarget = categoryMappingTarget
    }

    public var hasValidTransactionConfidence: Bool {
        guard let value = transactionConfidence else { return true }
        return value.isFinite && (0...1).contains(value)
            && value + 0.000001 >= confidence
            && source == .model && systemAction == .transaction
            && categoryMappingTarget == nil
            && SiftTaxonomy.leaf(id: labelID)?.systemAction == .transaction
    }

    public var routingConfidence: Double {
        hasValidTransactionConfidence ? transactionConfidence ?? confidence : .nan
    }

    public func applying(categoryMappings: [String: CategoryMappingTarget]) -> ClassificationDecision {
        guard
            source != .rule,
            source != .fallback,
            systemAction != .none,
            confidence.isFinite, (0...1).contains(confidence),
            hasValidTransactionConfidence,
            // A coarse business prediction cannot justify a user override
            // attached to a particular uncertain leaf (especially .junk).
            transactionConfidence == nil || confidence >= 0.5,
            CategoryMappingPolicy.isEligibleSource(labelID: labelID),
            let target = categoryMappings[labelID]
        else {
            return self
        }
        return ClassificationDecision(
            labelID: labelID,
            labelTitle: labelTitle,
            groupID: groupID,
            groupTitle: groupTitle,
            confidence: confidence,
            systemAction: target.systemAction,
            source: source,
            categoryMappingTarget: target
        )
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
