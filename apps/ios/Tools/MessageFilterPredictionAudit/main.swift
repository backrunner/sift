import Foundation
import MessageFilterCore

// Executes the real policy engine with saved classifier outputs. This does
// not validate Core ML conversion, model loading, failures, or device memory.
private struct Prediction: Decodable, Equatable, Sendable {
    let text: String
    let label: String
    let prediction: String
    let confidence: Double
    let probabilities: [String: Double]?
    let actionProbabilities: [String: Double]?
    let headPreference: Double?
    let directionPreferences: [String: Double]?
}

private struct FrozenClassifier: MessageClassifier {
    let predictions: [String: Prediction]
    let decisionPolicy: TransformerDecisionPolicy
    let actionFusionEnabled: Bool
    let businessCorrectionEnabled: Bool
    let expertRoutingEnabled: Bool
    let directionalRoutingEnabled: Bool

    func classify(sender: String?, body: String) -> ClassificationDecision {
        if directionalRoutingEnabled, let row = predictions[body], let fine = row.probabilities,
           let head = row.actionProbabilities, let preferences = row.directionPreferences,
           let decision = TransformerDirectionalRouting.decision(fineProbabilities: fine,
                actionProbabilities: head, preferences: preferences) {
            return decision
        }
        if expertRoutingEnabled, let row = predictions[body], let fine = row.probabilities,
           let head = row.actionProbabilities, let preference = row.headPreference,
           let decision = TransformerExpertRouting.decision(fineProbabilities: fine,
                actionProbabilities: head, headPreference: preference) {
            return decision
        }
        if actionFusionEnabled, let row = predictions[body],
           let fine = row.probabilities, let head = row.actionProbabilities,
           let decision = businessCorrectionEnabled
            ? TransformerBusinessCorrection.decision(fineProbabilities: fine, actionProbabilities: head)
            : TransformerActionFusion.decision(fineProbabilities: fine, actionProbabilities: head) {
            return decision
        }
        if let probabilities = predictions[body]?.probabilities,
           let summary = TransformerProbabilityDecision(probabilities: probabilities, policy: decisionPolicy) {
            return summary.decision()
        }
        guard let prediction = predictions[body],
              let leaf = SiftTaxonomy.leaf(id: prediction.prediction),
              prediction.confidence >= 0.5 else {
            return ModelOutputContract.abstentionDecision(confidence: predictions[body]?.confidence ?? 0)
        }
        return ClassificationDecision(
            labelID: leaf.id, labelTitle: leaf.title,
            groupID: leaf.groupId, groupTitle: leaf.groupTitle,
            confidence: prediction.confidence, systemAction: leaf.systemAction, source: .model
        )
    }
}

private struct FrozenLoader: TransformerRuntimeLoading {
    let classifier: FrozenClassifier

    @concurrent
    func loadTransformer(identity: ModelArtifactIdentity) async -> TransformerRuntimeLoadResult {
        TransformerRuntimeLoadResult(classifier: classifier)
    }
}

private struct AuditRow: Encodable {
    let index: Int
    let label: String
    let rawPrediction: String
    let confidence: Double
    let expectedAction: SystemAction
    let fixedThresholdLabel: String
    let fixedThresholdAction: SystemAction
    let engineLabel: String
    let engineAction: SystemAction
    let engineSubAction: SystemSubAction
    let leafConfidence: Double
    let transactionConfidence: Double?
    let fallbackReason: MessageFilterFallbackReason
    let modelRoutingBranch: String?
}

private enum AuditError: Error {
    case arguments
    case invalidRow(Int)
    case conflictingPrediction(String)
    case unexpectedFallback(Int)
    case existingOutput
}

private func run() async throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 || arguments.count == 4 || arguments.count == 5 else { throw AuditError.arguments }
    let businessCorrectionEnabled = arguments.count == 4 && arguments[3] == "--business-correction"
    let expertRoutingEnabled = arguments.count == 4 && arguments[3] == "--expert-routing"
    let directionalRoutingEnabled = arguments.count == 4 && arguments[3] == "--directional-routing"
    let actionFusionEnabled = directionalRoutingEnabled || expertRoutingEnabled || businessCorrectionEnabled || (arguments.count == 4 && arguments[3] == "--action-fusion")
    guard arguments.count != 4 || actionFusionEnabled else { throw AuditError.arguments }
    let decisionPolicy: TransformerDecisionPolicy
    if arguments.count == 5 {
        guard arguments[3] == "--transaction-mass-floor",
              let value = Double(arguments[4]), value.isFinite, (0.60...1).contains(value) else {
            throw AuditError.arguments
        }
        decisionPolicy = .qualifiedTransactionSum(minimumMass: value)
    } else {
        decisionPolicy = actionFusionEnabled ? .leaf : .transactionSum
    }
    let input = URL(fileURLWithPath: arguments[1])
    let output = URL(fileURLWithPath: arguments[2])
    guard !FileManager.default.fileExists(atPath: output.path) else { throw AuditError.existingOutput }
    let decoder = JSONDecoder()
    let rows = try String(contentsOf: input, encoding: .utf8).split(separator: "\n").map {
        try decoder.decode(Prediction.self, from: Data($0.utf8))
    }
    var predictions: [String: Prediction] = [:]
    for (index, row) in rows.enumerated() {
        guard !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              row.confidence.isFinite, (0...1).contains(row.confidence),
              SiftTaxonomy.leaf(id: row.label) != nil || ModelOutputContract.isAbstainLabel(row.label),
              SiftTaxonomy.leaf(id: row.prediction) != nil || ModelOutputContract.isAbstainLabel(row.prediction)
        else { throw AuditError.invalidRow(index) }
        if let probabilities = row.probabilities {
            guard let summary = TransformerProbabilityDecision(probabilities: probabilities, policy: decisionPolicy),
                  summary.labelID == row.prediction,
                  abs(summary.confidence - row.confidence) < 0.00001 else {
                throw AuditError.invalidRow(index)
            }
        }
        if actionFusionEnabled {
            guard let fine = row.probabilities, let head = row.actionProbabilities,
                  TransformerActionFusion.decision(fineProbabilities: fine, actionProbabilities: head) != nil else {
                throw AuditError.invalidRow(index)
            }
        } else if row.actionProbabilities != nil {
            throw AuditError.invalidRow(index)
        }
        if expertRoutingEnabled {
            guard let fine = row.probabilities, let head = row.actionProbabilities,
                  let preference = row.headPreference,
                  TransformerExpertRouting.decision(fineProbabilities: fine,
                    actionProbabilities: head, headPreference: preference) != nil else {
                throw AuditError.invalidRow(index)
            }
        } else if row.headPreference != nil { throw AuditError.invalidRow(index) }
        if directionalRoutingEnabled {
            guard let fine = row.probabilities, let head = row.actionProbabilities,
                  let preferences = row.directionPreferences,
                  TransformerDirectionalRouting.decision(fineProbabilities: fine,
                    actionProbabilities: head, preferences: preferences) != nil else {
                throw AuditError.invalidRow(index)
            }
        } else if row.directionPreferences != nil { throw AuditError.invalidRow(index) }
        if let prior = predictions[row.text], prior.prediction != row.prediction || prior.confidence != row.confidence
            || prior.probabilities != row.probabilities || prior.actionProbabilities != row.actionProbabilities
            || prior.headPreference != row.headPreference || prior.directionPreferences != row.directionPreferences {
            throw AuditError.conflictingPrediction(row.text)
        }
        predictions[row.text] = row
    }
    let classifier = FrozenClassifier(predictions: predictions, decisionPolicy: decisionPolicy,
                                      actionFusionEnabled: actionFusionEnabled,
                                      businessCorrectionEnabled: businessCorrectionEnabled,
                                      expertRoutingEnabled: expertRoutingEnabled,
                                      directionalRoutingEnabled: directionalRoutingEnabled)
    let engine = MessageFilterEngine(
        classicClassifier: classifier,
        transformerLoader: FrozenLoader(classifier: classifier),
        transformerDeviceSupport: .supported
    )
    let identity = ModelArtifactIdentity(variant: .transformer, modelABI: "prediction-policy-audit", releaseSequence: 1, sha256: "saved-predictions")
    let configuration = FilterConfigurationSnapshot(
        generation: 1, selectedVariant: .transformer,
        modelArtifactIdentity: identity, rules: [], categoryMappings: [:]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = Data()
    for (index, row) in rows.enumerated() {
        let threshold = ModelOutputContract.validatedDecision(
            classifier.classify(sender: nil, body: row.text), minimumConfidence: 0.5
        )
        let result = await engine.classify(
            MessageFilterRequest(sender: nil, body: row.text), configuration: configuration
        )
        guard result.fallbackReason == .none else { throw AuditError.unexpectedFallback(index) }
        let audit = AuditRow(
            index: index, label: row.label, rawPrediction: row.prediction, confidence: row.confidence,
            expectedAction: SiftTaxonomy.leaf(id: row.label)?.systemAction ?? .none,
            fixedThresholdLabel: threshold.labelID, fixedThresholdAction: threshold.systemAction,
            engineLabel: result.decision.labelID, engineAction: result.systemAction,
            engineSubAction: result.systemSubAction, leafConfidence: result.decision.confidence,
            transactionConfidence: result.decision.transactionConfidence,
            fallbackReason: result.fallbackReason,
            modelRoutingBranch: directionalRoutingEnabled
                ? TransformerDirectionalRouting.branch(fineProbabilities: row.probabilities!,
                    actionProbabilities: row.actionProbabilities!)?.rawValue : nil
        )
        data.append(try encoder.encode(audit)); data.append(0x0a)
    }
    await engine.handleSignalMemoryPressure()
    try data.write(to: output, options: .atomic)
    print("Audited \(rows.count) saved predictions through MessageFilterEngine; no Core ML/device claim.")
}

try await run()
