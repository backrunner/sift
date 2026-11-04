import Foundation
@testable import MessageFilterCore
import Testing
#if canImport(CoreML)
import CoreML
#endif

private func distribution(_ entries: [String: Double]) -> [String: Double] {
    var values = Dictionary(uniqueKeysWithValues: SiftTaxonomy.leaves.map { ($0.id, 0.0) })
    values[ModelOutputContract.abstainLabel] = 0
    for (label, value) in entries { values[label] = value }
    return values
}

@Test
func transactionAggregationPreservesLeafAndRestrictsSubaction() throws {
    let values = distribution(["finance.bank": 0.35, "finance.income": 0.30, "transaction.order": 0.25,
                               ModelOutputContract.abstainLabel: 0.10])
    let summary = try #require(TransformerProbabilityDecision(probabilities: values, policy: .transactionSum))
    let decision = summary.decision()
    #expect(decision.labelID == "finance.bank")
    #expect(abs(decision.confidence - 0.35) < 1e-12)
    #expect(abs((decision.transactionConfidence ?? 0) - 0.90) < 1e-12)
    #expect(MessageFilterRouting.systemAction(for: decision) == .transaction)
    #expect(MessageFilterRouting.systemSubAction(for: decision) == .none)
    #expect(TransformerProbabilityDecision(probabilities: values, policy: .leaf)?.decision().systemAction == SystemAction.none)
    let roundTrip = try JSONDecoder().decode(ClassificationDecision.self, from: JSONEncoder().encode(decision))
    #expect(roundTrip == decision)
}

@Test
func transactionAggregationCannotBoostJunkPromotionOrAbstention() throws {
    for label in ["spam", "promotion", "carrier.promotion", ModelOutputContract.abstainLabel] {
        let values = distribution([label: 0.4, "finance.bank": 0.3, "finance.income": 0.3])
        let summary = try #require(TransformerProbabilityDecision(probabilities: values, policy: .transactionSum))
        #expect(summary.labelID == label)
        #expect(summary.transactionConfidence == nil)
        #expect(summary.decision().systemAction == .none)
    }
}

@Test
func malformedProbabilityDistributionsFailClosed() {
    let valid = distribution(["finance.bank": 0.7, ModelOutputContract.abstainLabel: 0.3])
    var missing = valid; missing.removeValue(forKey: "spam")
    var unknown = valid; unknown["future.unknown"] = 0
    var negative = valid; negative["spam"] = -0.1
    var nonfinite = valid; nonfinite["spam"] = .nan
    var logits = valid; logits["finance.bank"] = 7
    var partial = valid; partial["finance.bank"] = 0.4
    for values in [missing, unknown, negative, nonfinite, logits, partial] {
        #expect(TransformerProbabilityDecision(probabilities: values, policy: .transactionSum) == nil)
    }
    var rounding = valid; rounding["finance.bank"] = 0.7000002
    #expect(TransformerProbabilityDecision(probabilities: rounding, policy: .transactionSum)?.decision().hasValidTransactionConfidence == true)
}

@Test
func uncertainLeafCannotBorrowActionMassForCustomJunkMapping() throws {
    let summary = try #require(TransformerProbabilityDecision(probabilities: distribution([
        "finance.bank": 0.35, "finance.income": 0.30, "transaction.order": 0.25,
        ModelOutputContract.abstainLabel: 0.10]), policy: .transactionSum))
    let mapped = summary.decision().applying(categoryMappings: ["finance.bank": .junk])
    #expect(mapped.categoryMappingTarget == nil)
    #expect(MessageFilterRouting.systemAction(for: mapped) == .transaction)
    let specific = try #require(TransformerProbabilityDecision(probabilities: distribution([
        "finance.bank": 0.8, ModelOutputContract.abstainLabel: 0.2]), policy: .transactionSum))
    let explicit = specific.decision().applying(categoryMappings: ["finance.bank": .junk])
    #expect(explicit.transactionConfidence == nil)
    #expect(MessageFilterRouting.systemAction(for: explicit) == .junk)
}

@Test
func invalidActionConfidenceNeverRescuesAnUnvalidatedDecision() {
    for mass in [Double.nan, Double.infinity, -0.1, 1.1, 0.1] {
        let decision = ClassificationDecision(labelID: "finance.bank", labelTitle: "", groupID: "finance",
            groupTitle: "", confidence: 0.2, systemAction: .transaction, source: .model,
            transactionConfidence: mass)
        #expect(ModelOutputContract.validatedDecision(decision, minimumConfidence: 0.5).systemAction == .none)
        #expect(MessageFilterRouting.systemAction(for: decision) == .none)
    }
    for source in [ClassificationSource.fallback, .rule, .personalization] {
        let decision = ClassificationDecision(labelID: "finance.bank", labelTitle: "", groupID: "finance",
            groupTitle: "", confidence: 0.2, systemAction: .transaction, source: source,
            transactionConfidence: 0.99)
        #expect(MessageFilterRouting.systemAction(for: decision) == .none)
    }
}

@Test
func qualifiedAggregationPreservesLeafFallbackAndCoarseUncertainty() throws {
    // Binary-exact values exercise the inclusive boundary without decimal
    // roundoff placing an intended 0.90 sum just below the actual floor.
    let uncertain = distribution(["finance.bank": 0.375, "finance.income": 0.25,
                                  "transaction.order": 0.25, ModelOutputContract.abstainLabel: 0.125])
    let below = try #require(TransformerProbabilityDecision(probabilities: uncertain,
        policy: .qualifiedTransactionSum(minimumMass: 0.95)))
    #expect(below.transactionConfidence == nil)
    #expect(below.decision() == TransformerProbabilityDecision(probabilities: uncertain, policy: .leaf)?.decision())
    let accepted = try #require(TransformerProbabilityDecision(probabilities: uncertain,
        policy: .qualifiedTransactionSum(minimumMass: 0.875)))
    #expect(MessageFilterRouting.systemAction(for: accepted.decision()) == .transaction)
    #expect(MessageFilterRouting.systemSubAction(for: accepted.decision()) == .none)
    #expect(accepted.decision().applying(categoryMappings: ["finance.bank": .junk]).categoryMappingTarget == nil)

    let confident = distribution(["finance.bank": 0.7, ModelOutputContract.abstainLabel: 0.3])
    let retained = try #require(TransformerProbabilityDecision(probabilities: confident,
        policy: .qualifiedTransactionSum(minimumMass: 0.95)))
    #expect(retained.transactionConfidence == nil)
    #expect(retained.decision() == TransformerProbabilityDecision(probabilities: confident, policy: .leaf)?.decision())
    #expect(MessageFilterRouting.systemAction(for: retained.decision()) == .transaction)
}

@Test
func qualifiedAggregationCannotBoostOtherActionsOrAcceptInvalidFloors() throws {
    for label in ["spam", "promotion", "carrier.promotion", ModelOutputContract.abstainLabel] {
        let values = distribution([label: 0.4, "finance.bank": 0.3, "finance.income": 0.3])
        let qualified = try #require(TransformerProbabilityDecision(probabilities: values,
            policy: .qualifiedTransactionSum(minimumMass: 0.60)))
        #expect(qualified.transactionConfidence == nil)
        #expect(qualified.decision() == TransformerProbabilityDecision(probabilities: values, policy: .leaf)?.decision())
    }
    let valid = distribution(["finance.bank": 0.7, ModelOutputContract.abstainLabel: 0.3])
    for invalid in [Double.nan, Double.infinity, -0.1, 0.59, 1.01] {
        #expect(TransformerProbabilityDecision(probabilities: valid,
            policy: .qualifiedTransactionSum(minimumMass: invalid)) == nil)
    }
    var truncated = valid
    truncated.removeValue(forKey: "spam")
    #expect(TransformerProbabilityDecision(probabilities: truncated,
        policy: .qualifiedTransactionSum(minimumMass: 0.95)) == nil)
}

#if canImport(CoreML)
private struct ActionFixtureTokenizer: TextTokenizing {
    func tokenizeText(_ text: String) -> TokenizedText {
        TokenizedText(inputIDs: [1, 2, 0, 0], attentionMask: [1, 1, 0, 0])
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SIFT_ACTION_COREML_FIXTURES"] != nil))
func actionConfidenceDecodesRealCoreMLTensorAndDictionaryOutputs() async throws {
    struct Specification: Decodable {
        struct Fixture: Decodable { let name: String; let expectedAction: String }
        let labels: [String]
        let cases: [Fixture]
    }
    let path = try #require(ProcessInfo.processInfo.environment["SIFT_ACTION_COREML_FIXTURES"])
    let directory = URL(fileURLWithPath: path)
    let spec = try JSONDecoder().decode(Specification.self,
        from: Data(contentsOf: directory.appendingPathComponent("fixtures.json")))
    for fixture in spec.cases {
        let compiled = try await MLModel.compileModel(at: directory.appendingPathComponent(fixture.name + ".mlmodel"))
        defer { try? FileManager.default.removeItem(at: compiled) }
        let policies: [(TransformerDecisionPolicy, Bool)] = [
            (.transactionSum, false), (.qualifiedTransactionSum(minimumMass: 0.80), false),
            (.qualifiedTransactionSum(minimumMass: 0.95), true)
        ]
        for (policy, rejectsBusiness) in policies {
            let classifier = try TransformerTextClassifier(modelURL: compiled,
                tokenizer: ActionFixtureTokenizer(), labels: spec.labels,
                computeUnits: "cpuOnly", decisionPolicy: policy)
            switch classifier.classificationResult(sender: nil, body: "opaque fixture") {
            case .failure(let error):
                #expect(fixture.expectedAction == "invalid")
                #expect(error == .invalidOutput)
            case .success(let decision):
                let expected = rejectsBusiness && fixture.expectedAction == "transaction" ? "none" : fixture.expectedAction
                #expect(MessageFilterRouting.systemAction(for: decision).rawValue == expected)
                if fixture.expectedAction == "transaction" {
                    #expect(abs(decision.confidence - 0.35) < 0.00001)
                    if rejectsBusiness {
                        #expect(decision.transactionConfidence == nil)
                    } else {
                        #expect(abs((decision.transactionConfidence ?? 0) - 0.9) < 0.00001)
                    }
                    #expect(MessageFilterRouting.systemSubAction(for: decision) == .none)
                }
            }
        }
    }
}
#endif
