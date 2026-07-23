import CoreML
import Foundation
import MessageFilterCore
import NaturalLanguage

private struct Arguments {
    let model: URL
    let fixed: URL
    let promotion: URL
    let billing: URL
    let conversation: URL
    let output: URL
    let confidenceThreshold: Double

    init(_ raw: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < raw.count {
            guard raw[index].hasPrefix("--"), index + 1 < raw.count else {
                throw SuiteError.invalidArguments
            }
            values[raw[index]] = raw[index + 1]
            index += 2
        }
        guard
            let model = values["--model"],
            let fixed = values["--fixed"],
            let promotion = values["--promotion"],
            let billing = values["--billing"],
            let conversation = values["--conversation"],
            let output = values["--output"]
        else {
            throw SuiteError.invalidArguments
        }
        self.model = URL(fileURLWithPath: model)
        self.fixed = URL(fileURLWithPath: fixed)
        self.promotion = URL(fileURLWithPath: promotion)
        self.billing = URL(fileURLWithPath: billing)
        self.conversation = URL(fileURLWithPath: conversation)
        self.output = URL(fileURLWithPath: output)
        let threshold = values["--confidence-threshold"].flatMap(Double.init) ?? 0.62
        guard (0...1).contains(threshold) else {
            throw SuiteError.invalidArguments
        }
        self.confidenceThreshold = threshold
    }
}

private enum SuiteError: Error {
    case invalidArguments
    case emptyDataset(String)
    case unknownLabel(String)
    case fixedGateFailed
    case promotionGateFailed
    case billingGateFailed
    case conversationGateFailed
    case unsafeActionGateFailed
}

private struct DatasetRow: Decodable {
    let text: String
    let label: String
}

private struct Failure: Encodable {
    let row: Int
    let expectedLabel: String
    let predictedLabel: String
    let confidence: Double
    let expectedAction: SystemAction
    let actualAction: SystemAction
}

private struct DatasetReport: Encodable {
    let count: Int
    let rawLabelAccuracy: Double
    let labelAccuracy: Double
    let actionAccuracy: Double
    let failures: [Failure]
}

private struct Report: Encodable {
    let suiteVersion: Int
    let modelBytes: Int64
    let fixed: DatasetReport
    let promotion: DatasetReport
    let billing: DatasetReport
    let conversation: DatasetReport
    let benignOrTransactionToJunk: Int
}

private func loadRows(at url: URL) throws -> [DatasetRow] {
    let decoder = JSONDecoder()
    let rows = try String(contentsOf: url, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map { try decoder.decode(DatasetRow.self, from: Data($0.utf8)) }
    guard !rows.isEmpty else {
        throw SuiteError.emptyDataset(url.path)
    }
    return rows
}

private func expectedAction(for label: String) throws -> SystemAction {
    if ModelOutputContract.isAbstainLabel(label) {
        return .none
    }
    guard let leaf = SiftTaxonomy.leaf(id: label) else {
        throw SuiteError.unknownLabel(label)
    }
    return leaf.systemAction
}

private func evaluate(
    _ rows: [DatasetRow],
    rawPredictions: [String],
    engine: MessageFilterEngine
) async throws -> (report: DatasetReport, unsafeJunk: Int) {
    precondition(rows.count == rawPredictions.count)
    var rawLabelCorrect = 0
    var labelCorrect = 0
    var actionCorrect = 0
    var unsafeJunk = 0
    var failures: [Failure] = []

    for (index, row) in rows.enumerated() {
        let expected = try expectedAction(for: row.label)
        rawLabelCorrect += rawPredictions[index] == row.label ? 1 : 0
        let result = await engine.classify(
            MessageFilterRequest(sender: nil, body: row.text),
            configuration: .classicDefault
        )
        let labelMatches = result.decision.labelID == row.label
        let actionMatches = result.systemAction == expected
        labelCorrect += labelMatches ? 1 : 0
        actionCorrect += actionMatches ? 1 : 0
        if expected == .none || expected == .transaction {
            unsafeJunk += result.systemAction == .junk ? 1 : 0
        }
        if !labelMatches || !actionMatches {
            failures.append(Failure(
                row: index,
                expectedLabel: row.label,
                predictedLabel: result.decision.labelID,
                confidence: result.decision.confidence,
                expectedAction: expected,
                actualAction: result.systemAction
            ))
        }
    }

    return (
        DatasetReport(
            count: rows.count,
            rawLabelAccuracy: Double(rawLabelCorrect) / Double(rows.count),
            labelAccuracy: Double(labelCorrect) / Double(rows.count),
            actionAccuracy: Double(actionCorrect) / Double(rows.count),
            failures: failures
        ),
        unsafeJunk
    )
}

private func run() async throws {
    let arguments = try Arguments(CommandLine.arguments)
    let compiledURL = try await MLModel.compileModel(at: arguments.model)
    defer { try? FileManager.default.removeItem(at: compiledURL) }
    let primary = try NLModelTextClassifier(
        modelURL: compiledURL,
        confidenceThreshold: arguments.confidenceThreshold
    )
    let classifier = CascadingClassifier(
        primary: primary,
        fallback: HeuristicClassifier(),
        primaryThreshold: arguments.confidenceThreshold
    )
    let engine = MessageFilterEngine(classicClassifier: classifier)
    let rawModel = try NLModel(contentsOf: compiledURL)
    let fixedRows = try loadRows(at: arguments.fixed)
    let promotionRows = try loadRows(at: arguments.promotion)
    let billingRows = try loadRows(at: arguments.billing)
    let conversationRows = try loadRows(at: arguments.conversation)

    let fixed = try await evaluate(
        fixedRows,
        rawPredictions: fixedRows.map { rawModel.predictedLabel(for: $0.text) ?? "<nil>" },
        engine: engine
    )
    let promotion = try await evaluate(
        promotionRows,
        rawPredictions: promotionRows.map { rawModel.predictedLabel(for: $0.text) ?? "<nil>" },
        engine: engine
    )
    let billing = try await evaluate(
        billingRows,
        rawPredictions: billingRows.map { rawModel.predictedLabel(for: $0.text) ?? "<nil>" },
        engine: engine
    )
    let conversation = try await evaluate(
        conversationRows,
        rawPredictions: conversationRows.map { rawModel.predictedLabel(for: $0.text) ?? "<nil>" },
        engine: engine
    )
    let modelBytes = (try FileManager.default.attributesOfItem(atPath: arguments.model.path)[.size] as? NSNumber)?.int64Value ?? 0
    let unsafeJunk = fixed.unsafeJunk + promotion.unsafeJunk + billing.unsafeJunk + conversation.unsafeJunk
    let report = Report(
        suiteVersion: 2,
        modelBytes: modelBytes,
        fixed: fixed.report,
        promotion: promotion.report,
        billing: billing.report,
        conversation: conversation.report,
        benignOrTransactionToJunk: unsafeJunk
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: arguments.output, options: .atomic)

    guard fixed.report.rawLabelAccuracy >= 0.98, fixed.report.actionAccuracy >= 0.98 else {
        throw SuiteError.fixedGateFailed
    }
    guard promotion.report.rawLabelAccuracy >= 0.95, promotion.report.actionAccuracy >= 0.85 else {
        throw SuiteError.promotionGateFailed
    }
    guard billing.report.rawLabelAccuracy >= 0.90, billing.report.actionAccuracy >= 0.95 else {
        throw SuiteError.billingGateFailed
    }
    guard
        conversation.report.rawLabelAccuracy == 1,
        conversation.report.labelAccuracy == 1,
        conversation.report.actionAccuracy == 1
    else {
        throw SuiteError.conversationGateFailed
    }
    guard unsafeJunk == 0 else {
        throw SuiteError.unsafeActionGateFailed
    }
}

do {
    try await run()
} catch {
    fputs("ClassicMessageFilterArtifactTests failed: \(error)\n", stderr)
    exit(1)
}
