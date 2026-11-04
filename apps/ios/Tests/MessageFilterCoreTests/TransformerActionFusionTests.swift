import Foundation
@testable import MessageFilterCore
import Testing

private func fineDistribution(_ values: [String: Double]) -> [String: Double] {
    var result = Dictionary(uniqueKeysWithValues: SiftTaxonomy.leaves.map { ($0.id, 0.0) })
    result[ModelOutputContract.abstainLabel] = 0
    return result.merging(values) { _, new in new }
}

private func actionDistribution(_ values: [String: Double]) -> [String: Double] {
    ["business": 0.0, "ordinary": 0.0, "commercial": 0.0, "harmful": 0.0].merging(values) { _, new in new }
}

@Test
func actionFusionProtectsConfidentNormalLeavesAgainstHarmfulHead() throws {
    for label in ["finance.consumption", "finance.credit_card", "carrier.data_reminder", ModelOutputContract.abstainLabel] {
        let fine = fineDistribution([label: 0.75, "spam": 0.25])
        let result = try #require(TransformerActionFusion.decision(fineProbabilities: fine,
            actionProbabilities: actionDistribution(["harmful": 1])))
        #expect(result == TransformerProbabilityDecision(probabilities: fine, policy: .leaf)?.decision())
    }
}

@Test
func actionFusionCannotDowngradeJunkOrPromotionToBusiness() throws {
    for label in ["spam", "promotion", "carrier.promotion"] {
        let fine = fineDistribution([label: 0.55, "finance.bank": 0.45])
        let result = try #require(TransformerActionFusion.decision(fineProbabilities: fine,
            actionProbabilities: actionDistribution(["business": 1])))
        #expect(result.labelID == label)
    }
    let fine = fineDistribution(["promotion": 0.9, "spam": 0.1])
    let upgraded = try #require(TransformerActionFusion.decision(fineProbabilities: fine,
        actionProbabilities: actionDistribution(["harmful": 0.99, "commercial": 0.01])))
    #expect(upgraded.systemAction == .junk)
}

@Test
func actionFusionPreservesFineConfidenceWhenRescuingAnUncertainBusiness() throws {
    let fine = fineDistribution(["finance.bank": 0.375, "finance.income": 0.25,
                                 "transaction.order": 0.25, ModelOutputContract.abstainLabel: 0.125])
    let result = try #require(TransformerActionFusion.decision(fineProbabilities: fine,
        actionProbabilities: actionDistribution(["business": 0.95, "ordinary": 0.05])))
    #expect(result.labelID == "finance.bank")
    #expect(result.confidence == 0.375)
    #expect(result.transactionConfidence == 0.875)
    #expect(MessageFilterRouting.systemAction(for: result) == .transaction)
    #expect(MessageFilterRouting.systemSubAction(for: result) == .none)
    #expect(result.applying(categoryMappings: ["finance.bank": .junk]).categoryMappingTarget == nil)
}

@Test
func actionFusionRequiresConfidentFilteringAndValidFullDistributions() throws {
    let fine = fineDistribution(["finance.bank": 0.375, "spam": 0.25,
                                 "promotion": 0.25, ModelOutputContract.abstainLabel: 0.125])
    let uncertain = try #require(TransformerActionFusion.decision(fineProbabilities: fine,
        actionProbabilities: actionDistribution(["harmful": 0.97, "ordinary": 0.03])))
    #expect(uncertain.systemAction == .none)
    let confident = try #require(TransformerActionFusion.decision(fineProbabilities: fine,
        actionProbabilities: actionDistribution(["harmful": 0.99, "ordinary": 0.01])))
    #expect(confident.systemAction == .junk)
    var missing = fine; missing.removeValue(forKey: "spam")
    #expect(TransformerActionFusion.decision(fineProbabilities: missing,
        actionProbabilities: actionDistribution(["business": 1])) == nil)
    for head in [["business": 1.0], actionDistribution(["business": .nan]),
                 actionDistribution(["business": 0.6]), actionDistribution(["business": 1.1, "harmful": -0.1])] {
        #expect(TransformerActionFusion.decision(fineProbabilities: fine, actionProbabilities: head) == nil)
    }
}
