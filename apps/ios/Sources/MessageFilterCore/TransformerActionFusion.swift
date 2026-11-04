import Foundation

/// Opt-in research path for a paired fine classifier and four-action head.
/// It is not enabled by downloaded models or model manifests.
public enum TransformerActionFusion {
    public static func decision(
        fineProbabilities: [String: Double],
        actionProbabilities: [String: Double]
    ) -> ClassificationDecision? {
        let keys = ["business", "commercial", "harmful", "ordinary"]
        guard Set(actionProbabilities.keys) == Set(keys),
              actionProbabilities.values.allSatisfy({ $0.isFinite && (0...1.000001).contains($0) }),
              let fine = TransformerProbabilityDecision(probabilities: fineProbabilities, policy: .leaf) else {
            return nil
        }
        let total = keys.reduce(0.0) { $0 + actionProbabilities[$1]! }
        guard abs(total - 1) <= 0.001 else { return nil }
        let head = actionProbabilities.mapValues { min(1, $0 / total) }
        let base = fine.decision()

        // Keep supported normal business leaves and explicit ordinary messages.
        // Coarse confidence must not erase an already supported fine category.
        let fineAction = SiftTaxonomy.leaf(id: fine.labelID)?.systemAction ?? .none
        if fine.confidence >= 0.60 && (fineAction == .transaction || fineAction == .none) {
            return base
        }
        // A recalled harmful message cannot be downgraded by the extra head.
        if base.systemAction == .junk { return base }

        func filtered(_ label: String, confidence: Double) -> ClassificationDecision {
            let leaf = SiftTaxonomy.leaf(id: label)!
            return ClassificationDecision(labelID: leaf.id, labelTitle: leaf.title,
                groupID: leaf.groupId, groupTitle: leaf.groupTitle, confidence: confidence,
                systemAction: leaf.systemAction, source: .model)
        }
        if head["harmful"]! >= 0.98 {
            return filtered("spam", confidence: head["harmful"]!)
        }
        // Keep an existing promotion unless there is confident harmful evidence.
        if base.systemAction == .promotion { return base }
        if head["commercial"]! >= 0.98 {
            return filtered("promotion", confidence: head["commercial"]!)
        }
        if head["business"]! >= 0.90 {
            let business = fineProbabilities.keys.sorted().filter {
                SiftTaxonomy.leaf(id: $0)?.systemAction == .transaction
            }
            let fineTotal = fineProbabilities.keys.sorted().reduce(0.0) { $0 + fineProbabilities[$1]! }
            let mass = min(1, business.reduce(0.0) { $0 + fineProbabilities[$1]! } / fineTotal)
            if mass >= 0.60, let best = business.max(by: { fineProbabilities[$0]! < fineProbabilities[$1]! }),
               let leaf = SiftTaxonomy.leaf(id: best) {
                // Keep the actual fine probability. The existing mapping and
                // subfolder guards handle uncertain leaves separately.
                return ClassificationDecision(labelID: leaf.id, labelTitle: leaf.title,
                    groupID: leaf.groupId, groupTitle: leaf.groupTitle,
                    confidence: min(1, fineProbabilities[best]! / fineTotal),
                    systemAction: .transaction, source: .model, transactionConfidence: mass)
            }
        }
        return base
    }
}
