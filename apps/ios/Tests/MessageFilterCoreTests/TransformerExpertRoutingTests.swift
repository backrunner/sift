import Foundation
@testable import MessageFilterCore
import Testing

private func routingFine(_ values: [String: Double]) -> [String: Double] {
    var p = Dictionary(uniqueKeysWithValues: SiftTaxonomy.leaves.map { ($0.id, 0.0) })
    p[ModelOutputContract.abstainLabel] = 0
    return p.merging(values) { _, new in new }
}
private func routingHead(_ values: [String: Double]) -> [String: Double] {
    ["business": 0.0, "ordinary": 0.0, "commercial": 0.0, "harmful": 0.0].merging(values) { _, new in new }
}

@Test
func expertRouterCanCorrectConfidentBusinessWithoutFakingFineConfidence() throws {
    let p = routingFine(["finance.bank": 0.75, "spam": 0.25])
    let h = routingHead(["harmful": 0.99, "business": 0.01])
    #expect(TransformerExpertRouting.decision(fineProbabilities: p, actionProbabilities: h, headPreference: 0)?.systemAction == .transaction)
    #expect(TransformerExpertRouting.decision(fineProbabilities: p, actionProbabilities: h, headPreference: 1)?.systemAction == .junk)
    let ordinary = try #require(TransformerExpertRouting.decision(fineProbabilities: p,
        actionProbabilities: routingHead(["ordinary": 1]), headPreference: 1))
    #expect(ordinary.systemAction == .none)
    #expect(ordinary.labelID == ModelOutputContract.abstainLabel)
}

@Test
func expertRouterBusinessActionKeepsUncertainFineAndMappingGuards() throws {
    let p = routingFine(["spam": 0.75, "finance.bank": 0.25])
    let d = try #require(TransformerExpertRouting.decision(fineProbabilities: p,
        actionProbabilities: routingHead(["business": 1]), headPreference: 1))
    #expect(d.confidence == 0.25)
    #expect(d.transactionConfidence == 1)
    #expect(MessageFilterRouting.systemAction(for: d) == .transaction)
    #expect(MessageFilterRouting.systemSubAction(for: d) == .none)
    #expect(d.applying(categoryMappings: ["finance.bank": .junk]).categoryMappingTarget == nil)
}

@Test
func expertRouterPreservesAgreedFineCategoryAndRejectsWeakHead() {
    let p = routingFine(["finance.bank": 0.75, "spam": 0.25])
    let base = TransformerProbabilityDecision(probabilities: p, policy: .leaf)?.decision()
    #expect(TransformerExpertRouting.decision(fineProbabilities: p,
        actionProbabilities: routingHead(["business": 0.9, "harmful": 0.1]), headPreference: 1) == base)
    #expect(TransformerExpertRouting.decision(fineProbabilities: p,
        actionProbabilities: routingHead(["harmful": 0.4, "ordinary": 0.3, "commercial": 0.3]), headPreference: 1) == base)
}

@Test
func expertRouterRejectsMalformedPreferencesAndDistributions() {
    let p = routingFine(["spam": 1]); let h = routingHead(["business": 1])
    for preference in [Double.nan, -0.01, 1.01] {
        #expect(TransformerExpertRouting.decision(fineProbabilities: p, actionProbabilities: h, headPreference: preference) == nil)
    }
    #expect(TransformerExpertRouting.decision(fineProbabilities: p, actionProbabilities: ["business": 1], headPreference: 1) == nil)
}
