import Foundation
@testable import MessageFilterCore
import Testing

private func fineRefinementDistribution(_ values: [String: Double]) -> [String: Double] {
    var p = Dictionary(uniqueKeysWithValues: SiftTaxonomy.leaves.map { ($0.id, 0.0) })
    p[ModelOutputContract.abstainLabel] = 0
    return p.merging(values) { _, v in v }
}

private func fineRefinementDecision(_ id: String, source: ClassificationSource = .model,
                                    mapping: CategoryMappingTarget? = nil) -> ClassificationDecision {
    let leaf = SiftTaxonomy.leaf(id: id)!
    return ClassificationDecision(labelID: id, labelTitle: leaf.title, groupID: leaf.groupId,
        groupTitle: leaf.groupTitle, confidence: 0.95, systemAction: leaf.systemAction,
        source: source, categoryMappingTarget: mapping)
}

@Test func fineRefinementCanCrossParentsWithoutChangingAction() {
    let old = fineRefinementDecision("work.meeting")
    let p = fineRefinementDistribution(["finance.wealth": 0.7, "work.meeting": 0.1, "spam": 0.2])
    let d = TransformerFineRefinement.decision(preserving: old, fineProbabilities: p)
    #expect(d.labelID == "finance.wealth")
    #expect(abs(d.confidence - 0.83125) < 0.000001)
    #expect(d.transactionConfidence == 0.95)
    #expect(MessageFilterRouting.systemAction(for: d) == .transaction)
    #expect(MessageFilterRouting.systemSubAction(for: d) == .transactionalFinance)
}

@Test func fineRefinementDoesNotForceWeakConditionalEvidence() {
    let old = fineRefinementDecision("finance.bank")
    for p in [fineRefinementDistribution(["finance.income": 0.49, "finance.bank": 0.46, "spam": 0.05]),
              fineRefinementDistribution(["finance.income": 0.1, "spam": 0.9])] {
        #expect(TransformerFineRefinement.decision(preserving: old, fineProbabilities: p) == old)
    }
}

@Test func fineRefinementRejectsInvalidDistributionsAndUserMappings() {
    let old = fineRefinementDecision("finance.bank")
    for p in [["finance.income": 1.0], fineRefinementDistribution(["finance.income": .nan]),
              fineRefinementDistribution(["finance.income": 1.1, "finance.bank": -0.1])] {
        #expect(TransformerFineRefinement.decision(preserving: old, fineProbabilities: p) == old)
    }
    for protected in [fineRefinementDecision("finance.bank", source: .rule),
                      fineRefinementDecision("finance.bank", source: .fallback),
                      fineRefinementDecision("finance.bank", mapping: .junk)] {
        #expect(TransformerFineRefinement.decision(preserving: protected,
            fineProbabilities: fineRefinementDistribution(["finance.income": 1])) == protected)
    }
}

@Test func fineRefinementPreservesEveryActionAcrossEveryLeafPair() {
    for before in SiftTaxonomy.leaves {
        let old = fineRefinementDecision(before.id)
        for candidate in SiftTaxonomy.leaves {
            let d = TransformerFineRefinement.decision(preserving: old,
                fineProbabilities: fineRefinementDistribution([candidate.id: 1]))
            #expect(MessageFilterRouting.systemAction(for: d) == MessageFilterRouting.systemAction(for: old))
            #expect(d.hasValidTransactionConfidence)
        }
    }
    let ordinary = ModelOutputContract.abstentionDecision(confidence: 0.99)
    #expect(TransformerFineRefinement.decision(preserving: ordinary,
        fineProbabilities: fineRefinementDistribution(["spam": 1])) == ordinary)
}
