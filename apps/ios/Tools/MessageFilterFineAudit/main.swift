import Foundation
import MessageFilterCore

// Research-only wrapper: real frozen v79 routing and engine, then opt-in fine
// refinement. Production MessageFilterEngine and the old audit remain unchanged.
private struct Prediction: Decodable, Equatable, Sendable {
    let text: String
    let label: String
    let prediction: String
    let confidence: Double
    let probabilities: [String: Double]
    let actionProbabilities: [String: Double]
    let directionPreferences: [String: Double]
    let refinementProbabilities: [String: Double]?
}
private struct FrozenClassifier: MessageClassifier {
    let predictions: [String: Prediction]
    func classify(sender: String?, body: String) -> ClassificationDecision {
        guard let p = predictions[body],
              let d = TransformerDirectionalRouting.decision(fineProbabilities: p.probabilities,
                actionProbabilities: p.actionProbabilities, preferences: p.directionPreferences)
        else { return ModelOutputContract.abstentionDecision(confidence: 0) }
        return d
    }
}
private struct FrozenLoader: TransformerRuntimeLoading {
    let classifier: FrozenClassifier
    @concurrent func loadTransformer(identity: ModelArtifactIdentity) async -> TransformerRuntimeLoadResult {
        TransformerRuntimeLoadResult(classifier: classifier)
    }
}
private struct AuditRow: Encodable {
    let index: Int
    let label: String
    let rawPrediction: String
    let confidence: Double
    let engineLabel: String
    let engineAction: SystemAction
    let engineSubAction: SystemSubAction
    let leafConfidence: Double
    let transactionConfidence: Double?
    let baselineLabel: String
    let baselineAction: SystemAction
    let baselineSubAction: SystemSubAction
    let routedLabel: String
    let routedAction: SystemAction
    let expectedSubAction: SystemSubAction
    let fallbackReason: MessageFilterFallbackReason
    let fineChanged: Bool
}
private enum AuditError: Error { case arguments, existingOutput, invalidRow(Int), conflictingPrediction, changedAction }

private func run() async throws {
    let args = CommandLine.arguments
    guard args.count == 3 else { throw AuditError.arguments }
    let output = URL(fileURLWithPath: args[2])
    guard !FileManager.default.fileExists(atPath: output.path) else { throw AuditError.existingOutput }
    let decoder = JSONDecoder()
    let rows = try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n").map {
        try decoder.decode(Prediction.self, from: Data($0.utf8))
    }
    var predictions: [String: Prediction] = [:]
    for (i, p) in rows.enumerated() {
        guard !p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              p.confidence.isFinite, (0...1).contains(p.confidence),
              SiftTaxonomy.leaf(id: p.label) != nil || ModelOutputContract.isAbstainLabel(p.label),
              let summary = TransformerProbabilityDecision(probabilities: p.probabilities, policy: .leaf),
              summary.labelID == p.prediction, abs(summary.confidence - p.confidence) < 0.000001,
              TransformerDirectionalRouting.decision(fineProbabilities: p.probabilities,
                actionProbabilities: p.actionProbabilities, preferences: p.directionPreferences) != nil
        else { throw AuditError.invalidRow(i) }
        if let fine = p.refinementProbabilities,
           TransformerProbabilityDecision(probabilities: fine, policy: .leaf) == nil { throw AuditError.invalidRow(i) }
        if let old = predictions[p.text], old != p { throw AuditError.conflictingPrediction }
        predictions[p.text] = p
    }
    let classifier = FrozenClassifier(predictions: predictions)
    let engine = MessageFilterEngine(classicClassifier: classifier,
        transformerLoader: FrozenLoader(classifier: classifier), transformerDeviceSupport: .supported)
    let identity = ModelArtifactIdentity(variant: .transformer, modelABI: "fine-refinement-audit",
        releaseSequence: 1, sha256: "saved-predictions")
    let configuration = FilterConfigurationSnapshot(generation: 1, selectedVariant: .transformer,
        modelArtifactIdentity: identity, rules: [], categoryMappings: [:])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var data = Data()
    for (i, row) in rows.enumerated() {
        let routed = classifier.classify(sender: nil, body: row.text)
        let result = await engine.classify(MessageFilterRequest(sender: nil, body: row.text), configuration: configuration)
        guard result.fallbackReason == .none else { throw AuditError.invalidRow(i) }
        let decision = row.refinementProbabilities.map {
            TransformerFineRefinement.decision(preserving: result.decision, fineProbabilities: $0)
        } ?? result.decision
        let action = MessageFilterRouting.systemAction(for: decision)
        guard action == result.systemAction else { throw AuditError.changedAction }
        let gold: ClassificationDecision
        if let leaf = SiftTaxonomy.leaf(id: row.label) {
            gold = ClassificationDecision(labelID: leaf.id, labelTitle: leaf.title, groupID: leaf.groupId,
                groupTitle: leaf.groupTitle, confidence: 1, systemAction: leaf.systemAction, source: .model)
        } else { gold = ModelOutputContract.abstentionDecision(confidence: 1) }
        let audit = AuditRow(index: i, label: row.label, rawPrediction: row.prediction, confidence: row.confidence,
            engineLabel: decision.labelID, engineAction: action,
            engineSubAction: MessageFilterRouting.systemSubAction(for: decision), leafConfidence: decision.confidence,
            transactionConfidence: decision.transactionConfidence, baselineLabel: result.decision.labelID,
            baselineAction: result.systemAction, baselineSubAction: result.systemSubAction,
            routedLabel: routed.labelID, routedAction: MessageFilterRouting.systemAction(for: routed),
            expectedSubAction: MessageFilterRouting.systemSubAction(for: gold), fallbackReason: result.fallbackReason,
            fineChanged: decision.labelID != result.decision.labelID)
        data.append(try encoder.encode(audit)); data.append(0x0a)
    }
    await engine.handleSignalMemoryPressure()
    try data.write(to: output, options: .atomic)
    print("Audited \(rows.count) rows with native fine refinement; production integration is not enabled.")
}
try await run()
