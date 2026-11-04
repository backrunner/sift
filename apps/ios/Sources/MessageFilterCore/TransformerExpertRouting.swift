import Foundation

/// Research-only expert selection. The preference is supplied by a separately
/// trained gate, not treated as confidence in a fine category.
public enum TransformerExpertRouting {
    public static func decision(
        fineProbabilities: [String: Double],
        actionProbabilities: [String: Double],
        headPreference: Double
    ) -> ClassificationDecision? {
        guard headPreference.isFinite, (0...1).contains(headPreference),
              TransformerActionFusion.decision(fineProbabilities: fineProbabilities,
                actionProbabilities: actionProbabilities) != nil,
              let fine = TransformerProbabilityDecision(probabilities: fineProbabilities, policy: .leaf) else {
            return nil
        }
        let base = fine.decision()
        guard headPreference >= 0.5 else { return base }
        let keys = actionProbabilities.keys.sorted()
        let total = keys.reduce(0.0) { $0 + actionProbabilities[$1]! }
        let best = keys.max(by: { actionProbabilities[$0]! < actionProbabilities[$1]! })!
        let probability = min(1, actionProbabilities[best]! / total)
        let action: SystemAction
        switch best {
        case "business": action = .transaction
        case "commercial": action = .promotion
        case "harmful": action = .junk
        default: action = .none
        }
        // Agreement retains the original fine category, confidence and routing.
        if MessageFilterRouting.systemAction(for: base) == action { return base }
        guard probability >= (action == .transaction ? 0.60 : 0.5) else { return base }
        if action == .none { return ModelOutputContract.abstentionDecision(confidence: probability) }
        if action == .transaction {
            let business = fineProbabilities.keys.sorted().filter {
                SiftTaxonomy.leaf(id: $0)?.systemAction == .transaction
            }
            guard let label = business.max(by: { fineProbabilities[$0]! < fineProbabilities[$1]! }),
                  let leaf = SiftTaxonomy.leaf(id: label) else { return nil }
            let fineTotal = fineProbabilities.keys.sorted().reduce(0.0) { $0 + fineProbabilities[$1]! }
            return ClassificationDecision(labelID: leaf.id, labelTitle: leaf.title,
                groupID: leaf.groupId, groupTitle: leaf.groupTitle,
                confidence: min(1, fineProbabilities[label]! / fineTotal),
                systemAction: .transaction, source: .model, transactionConfidence: probability)
        }
        let leaf = SiftTaxonomy.leaf(id: action == .junk ? "spam" : "promotion")!
        return ClassificationDecision(labelID: leaf.id, labelTitle: leaf.title,
            groupID: leaf.groupId, groupTitle: leaf.groupTitle,
            confidence: probability, systemAction: action, source: .model)
    }
}
