import Foundation

/// Explicit research-only correction of an original junk decision.
/// Head confidence authorizes an action, never a fine category or subfolder.
public enum TransformerBusinessCorrection {
    public static func decision(
        fineProbabilities: [String: Double],
        actionProbabilities: [String: Double]
    ) -> ClassificationDecision? {
        guard let locked = TransformerActionFusion.decision(
            fineProbabilities: fineProbabilities, actionProbabilities: actionProbabilities),
              let fine = TransformerProbabilityDecision(probabilities: fineProbabilities, policy: .leaf) else {
            return nil
        }
        guard fine.decision().systemAction == .junk else { return locked }
        let headTotal = actionProbabilities.keys.sorted().reduce(0.0) { $0 + actionProbabilities[$1]! }
        let business = actionProbabilities["business"]! / headTotal
        let harmful = actionProbabilities["harmful"]! / headTotal
        guard business >= 0.995, harmful <= 0.001 else { return locked }
        let alternatives = fineProbabilities.keys.sorted().filter { $0 != fine.labelID }
        guard let best = alternatives.max(by: { fineProbabilities[$0]! < fineProbabilities[$1]! }),
              let leaf = SiftTaxonomy.leaf(id: best), leaf.systemAction == .transaction else { return locked }
        let fineTotal = fineProbabilities.keys.sorted().reduce(0.0) { $0 + fineProbabilities[$1]! }
        return ClassificationDecision(labelID: leaf.id, labelTitle: leaf.title,
            groupID: leaf.groupId, groupTitle: leaf.groupTitle,
            confidence: min(1, fineProbabilities[best]! / fineTotal),
            systemAction: .transaction, source: .model, transactionConfidence: min(1, business))
    }
}
