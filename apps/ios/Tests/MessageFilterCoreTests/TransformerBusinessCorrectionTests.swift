import Foundation
@testable import MessageFilterCore
import Testing

private func correctionFine(_ values: [String: Double]) -> [String: Double] {
    var result = Dictionary(uniqueKeysWithValues: SiftTaxonomy.leaves.map { ($0.id, 0.0) })
    result[ModelOutputContract.abstainLabel] = 0
    return result.merging(values) { _, new in new }
}

private let confidentBusiness = ["business": 0.998, "ordinary": 0.001, "commercial": 0.0005, "harmful": 0.0005]

@Test
func businessCorrectionUsesHeadForActionAndRealFineConfidenceForCategory() throws {
    let fine = correctionFine(["spam": 0.75, "finance.bank": 0.125, "finance.income": 0.125])
    let result = try #require(TransformerBusinessCorrection.decision(fineProbabilities: fine, actionProbabilities: confidentBusiness))
    #expect(result.confidence == 0.125)
    #expect(abs(try #require(result.transactionConfidence) - 0.998) < 0.000001)
    #expect(MessageFilterRouting.systemAction(for: result) == .transaction)
    #expect(MessageFilterRouting.systemSubAction(for: result) == .none)
    #expect(result.applying(categoryMappings: [result.labelID: .junk]).categoryMappingTarget == nil)
}

@Test
func businessCorrectionRejectsHarmfulUncertaintyAndNonbusinessAlternative() throws {
    let fine = correctionFine(["spam": 0.75, "finance.bank": 0.25])
    for head in [
        ["business": 0.994, "ordinary": 0.005, "commercial": 0.0005, "harmful": 0.0005],
        ["business": 0.996, "ordinary": 0.001, "commercial": 0.001, "harmful": 0.002]
    ] {
        let result = try #require(TransformerBusinessCorrection.decision(fineProbabilities: fine, actionProbabilities: head))
        #expect(result.systemAction == .junk)
    }
    for label in ["promotion", ModelOutputContract.abstainLabel] {
        let alternate = correctionFine(["spam": 0.75, label: 0.25])
        #expect(TransformerBusinessCorrection.decision(fineProbabilities: alternate, actionProbabilities: confidentBusiness)?.systemAction == .junk)
    }
}

@Test
func businessCorrectionKeepsEveryOtherFusionPathAndRejectsMalformedHeads() {
    for label in ["finance.bank", "promotion", ModelOutputContract.abstainLabel] {
        let fine = correctionFine([label: 0.75, "spam": 0.25])
        #expect(TransformerBusinessCorrection.decision(fineProbabilities: fine, actionProbabilities: confidentBusiness)
            == TransformerActionFusion.decision(fineProbabilities: fine, actionProbabilities: confidentBusiness))
    }
    #expect(TransformerBusinessCorrection.decision(fineProbabilities: correctionFine(["spam": 1]),
        actionProbabilities: ["business": 1]) == nil)
}
