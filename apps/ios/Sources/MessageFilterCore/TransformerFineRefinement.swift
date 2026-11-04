import Foundation

/// Research-only post-engine refinement. No production caller enables it.
/// The existing final action remains authoritative; a second head can supply
/// a better leaf within that action, including across taxonomy parent groups.
public enum TransformerFineRefinement {
    public static func decision(
        preserving original: ClassificationDecision,
        fineProbabilities: [String: Double]
    ) -> ClassificationDecision {
        let action = MessageFilterRouting.systemAction(for: original)
        guard original.source == .model, original.categoryMappingTarget == nil,
              action == .transaction || action == .promotion,
              let _ = TransformerProbabilityDecision(probabilities: fineProbabilities, policy: .leaf)
        else { return original }

        let candidates = SiftTaxonomy.leaves.filter { $0.systemAction == action }
        let mass = candidates.reduce(0.0) { $0 + (fineProbabilities[$1.id] ?? 0) }
        guard mass >= 0.20 else { return original }
        let ordered = candidates.sorted {
            let a = fineProbabilities[$0.id] ?? 0
            let b = fineProbabilities[$1.id] ?? 0
            return a == b ? $0.id < $1.id : a > b
        }
        guard let leaf = ordered.first, leaf.id != original.labelID else { return original }
        let conditional = (fineProbabilities[leaf.id] ?? 0) / mass
        let previous = (fineProbabilities[original.labelID] ?? 0) / mass
        // A hierarchical joint estimate, bounded by the retained coarse support.
        // Do not report the conditional probability as an unconditional leaf one.
        let joint = conditional * original.routingConfidence
        guard joint >= 0.60, conditional - previous >= 0.10 else { return original }
        let refined = ClassificationDecision(
            labelID: leaf.id, labelTitle: leaf.title, groupID: leaf.groupId,
            groupTitle: leaf.groupTitle, confidence: joint, systemAction: action,
            source: .model,
            transactionConfidence: action == .transaction ? original.routingConfidence : nil
        )
        guard MessageFilterRouting.systemAction(for: refined) == action else { return original }
        return refined
    }
}
