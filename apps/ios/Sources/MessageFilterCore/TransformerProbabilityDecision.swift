import Foundation

/// The sum policy is opt-in for local qualification. Downloaded models keep
/// their existing leaf policy until a model-specific release is validated.
public enum TransformerDecisionPolicy: Sendable {
    case leaf
    case transactionSum
    /// Local qualification only. Below this mass, preserve the leaf policy.
    case qualifiedTransactionSum(minimumMass: Double)

    var requiresFullDistribution: Bool {
        switch self {
        case .leaf: false
        case .transactionSum, .qualifiedTransactionSum: true
        }
    }
}

public struct TransformerProbabilityDecision: Sendable {
    public let labelID: String
    public let confidence: Double
    public let transactionConfidence: Double?

    public init?(probabilities: [String: Double], policy: TransformerDecisionPolicy) {
        let minimumMass: Double?
        switch policy {
        case .leaf:
            minimumMass = nil
        case .transactionSum:
            minimumMass = 0
        case .qualifiedTransactionSum(let value):
            guard value.isFinite, (0.60...1).contains(value) else { return nil }
            minimumMass = value
        }
        let expected = Set(SiftTaxonomy.leaves.map(\.id)).union([ModelOutputContract.abstainLabel])
        guard Set(probabilities.keys) == expected,
              probabilities.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1.000001 }) else {
            return nil
        }
        // Accumulate in Double and normalize only floating-point roundoff.
        // Do not turn logits, truncated dictionaries or malformed output into
        // an apparently confident action.
        let ordered = probabilities.keys.sorted()
        let total = ordered.reduce(0.0) { $0 + probabilities[$1]! }
        guard abs(total - 1) <= 0.001,
              let best = ordered.max(by: { probabilities[$0]! < probabilities[$1]! }) else {
            return nil
        }
        self.labelID = best
        self.confidence = min(1, probabilities[best]! / total)
        if let minimumMass, SiftTaxonomy.leaf(id: best)?.systemAction == .transaction {
            let mass = ordered.filter { SiftTaxonomy.leaf(id: $0)?.systemAction == .transaction }
                .reduce(0.0) { $0 + probabilities[$1]! }
            let normalizedMass = min(1, max(0, mass / total))
            self.transactionConfidence = normalizedMass >= minimumMass ? normalizedMass : nil
        } else {
            self.transactionConfidence = nil
        }
    }

    public func decision(minimumConfidence: Double = 0.5) -> ClassificationDecision {
        guard let leaf = SiftTaxonomy.leaf(id: labelID) else {
            return ModelOutputContract.abstentionDecision(confidence: confidence)
        }
        return ModelOutputContract.validatedDecision(ClassificationDecision(
            labelID: leaf.id, labelTitle: leaf.title, groupID: leaf.groupId,
            groupTitle: leaf.groupTitle, confidence: confidence,
            systemAction: leaf.systemAction, source: .model,
            transactionConfidence: transactionConfidence
        ), minimumConfidence: minimumConfidence)
    }
}
