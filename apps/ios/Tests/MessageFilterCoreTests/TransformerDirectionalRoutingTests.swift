import Foundation
@testable import MessageFilterCore
import Testing

private func directionalFine(_ values: [String: Double]) -> [String: Double] {
    var p = Dictionary(uniqueKeysWithValues: SiftTaxonomy.leaves.map { ($0.id, 0.0) })
    p[ModelOutputContract.abstainLabel] = 0
    return p.merging(values) { _, new in new }
}
private func directionalHead(_ values: [String: Double]) -> [String: Double] {
    ["business": 0.0, "ordinary": 0.0, "commercial": 0.0, "harmful": 0.0].merging(values) { _, new in new }
}

@Test
func directionalRecoveryDoesNotAuthorizeEscalation() throws {
    let gates = ["recovery": 1.0, "escalation": 0.0, "refinement": 0.0]
    let filtered = directionalFine(["spam": 0.8, "finance.bank": 0.2])
    let business = directionalHead(["business": 1])
    #expect(TransformerDirectionalRouting.branch(fineProbabilities: filtered, actionProbabilities: business) == .recovery)
    let d = try #require(TransformerDirectionalRouting.decision(fineProbabilities: filtered, actionProbabilities: business, preferences: gates))
    #expect(MessageFilterRouting.systemAction(for: d) == .transaction)
    #expect(d.confidence == 0.2)
    #expect(MessageFilterRouting.systemSubAction(for: d) == .none)
    #expect(d.applying(categoryMappings: ["finance.bank": .junk]).categoryMappingTarget == nil)
    let normal = directionalFine(["finance.bank": 0.8, "spam": 0.2])
    let harmful = directionalHead(["harmful": 1])
    #expect(TransformerDirectionalRouting.branch(fineProbabilities: normal, actionProbabilities: harmful) == .escalation)
    #expect(TransformerDirectionalRouting.decision(fineProbabilities: normal, actionProbabilities: harmful, preferences: gates)?.systemAction == .transaction)
}

@Test
func directionalRefinementAndWeakHeadKeepTheirOwnBranch() {
    let p = directionalFine(["finance.bank": 0.8, "spam": 0.2])
    let weak = directionalHead(["harmful": 0.4, "ordinary": 0.3, "commercial": 0.3])
    #expect(TransformerDirectionalRouting.branch(fineProbabilities: p, actionProbabilities: weak) == .refinement)
    let ordinary = directionalHead(["ordinary": 1])
    let off = ["recovery": 1.0, "escalation": 1.0, "refinement": 0.0]
    #expect(TransformerDirectionalRouting.decision(fineProbabilities: p, actionProbabilities: ordinary, preferences: off)?.labelID == "finance.bank")
    #expect(TransformerDirectionalRouting.decision(fineProbabilities: p, actionProbabilities: ordinary,
        preferences: ["recovery": 0, "escalation": 0, "refinement": 1])?.labelID == ModelOutputContract.abstainLabel)
}

@Test
func directionalBranchUsesRoutedActionAndRejectsIncompletePreferences() {
    let p = directionalFine(["spam": 0.4, "finance.bank": 0.35, "promotion": 0.25])
    let harmful = directionalHead(["harmful": 1])
    // The fine top is spam but below its action threshold; it routes to none.
    #expect(TransformerDirectionalRouting.branch(fineProbabilities: p, actionProbabilities: harmful) == .escalation)
    for preferences in [["recovery": 1.0], ["recovery": 1, "escalation": 0, "refinement": Double.nan],
                        ["recovery": 1, "escalation": -0.1, "refinement": 0],
                        ["recovery": 1, "escalation": 0, "refinement": 0, "unknown": 0]] {
        #expect(TransformerDirectionalRouting.decision(fineProbabilities: p, actionProbabilities: harmful, preferences: preferences) == nil)
    }
}
