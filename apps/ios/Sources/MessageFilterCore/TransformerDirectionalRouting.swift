import Foundation

/// Research-only gates with separate risk estimates for opposite changes.
/// A branch depends only on the two model decisions, never a gold label.
public enum TransformerDirectionalRouting {
    public enum Branch: String, CaseIterable, Sendable {
        case recovery, escalation, refinement
    }

    public static func branch(
        fineProbabilities: [String: Double], actionProbabilities: [String: Double]
    ) -> Branch? {
        guard let fine = TransformerExpertRouting.decision(fineProbabilities: fineProbabilities,
                actionProbabilities: actionProbabilities, headPreference: 0),
              let candidate = TransformerExpertRouting.decision(fineProbabilities: fineProbabilities,
                actionProbabilities: actionProbabilities, headPreference: 1) else { return nil }
        let before = MessageFilterRouting.systemAction(for: fine)
        let after = MessageFilterRouting.systemAction(for: candidate)
        let wasFiltered = before == .junk || before == .promotion
        let isFiltered = after == .junk || after == .promotion
        if wasFiltered && !isFiltered { return .recovery }
        if !wasFiltered && isFiltered { return .escalation }
        return .refinement
    }

    public static func decision(
        fineProbabilities: [String: Double], actionProbabilities: [String: Double],
        preferences: [String: Double]
    ) -> ClassificationDecision? {
        guard Set(preferences.keys) == Set(Branch.allCases.map(\.rawValue)),
              preferences.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              let branch = branch(fineProbabilities: fineProbabilities, actionProbabilities: actionProbabilities)
        else { return nil }
        return TransformerExpertRouting.decision(fineProbabilities: fineProbabilities,
            actionProbabilities: actionProbabilities, headPreference: preferences[branch.rawValue]!)
    }
}
