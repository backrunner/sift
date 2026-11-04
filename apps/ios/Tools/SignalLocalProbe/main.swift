import Darwin
import Foundation
import MessageFilterCore

// Local qualification only: real Core ML model and production engine in one process.
// A Mac footprint is not an iPhone or IdentityLookup result, so compare it with the control.
// Usage: SignalLocalProbe <modelDir> <rows.ndjson> <report.json> [decisions.ndjson] [--repeat N] [--prepare]

private struct Row: Decodable { let text: String; let label: String }

private struct Loader: TransformerRuntimeLoading {
    let classifier: TransformerTextClassifier
    @concurrent func loadTransformer(identity: ModelArtifactIdentity) async -> TransformerRuntimeLoadResult {
        TransformerRuntimeLoadResult(classifier: classifier)
    }
}

private struct Decision: Encodable {
    let index: Int
    let text: String
    let label: String
    let rawPrediction: String
    let confidence: Double
    let engineLabel: String
    let engineAction: SystemAction
    let engineSubAction: SystemSubAction
    let fallbackReason: MessageFilterFallbackReason
}

private struct Report: Encodable {
    let version: String
    let releaseSequence: Int
    let routed: Bool
    let contractAccepted: Bool
    let downloadBytes: Int64
    let inferences: Int
    let failures: Int
    let initialFootprint: UInt64
    let afterLoadFootprint: UInt64
    let finalFootprint: UInt64
    let peakFootprint: UInt64
    let loadMilliseconds: Double
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double
}

private func footprint() -> (current: UInt64, peak: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    return (UInt64(info.phys_footprint), UInt64(info.ledger_phys_footprint_peak))
}

private func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
}

private func run() async throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 4 else { throw CocoaError(.featureUnsupported) }
    let directory = URL(fileURLWithPath: arguments[1])
    let rows = try String(contentsOfFile: arguments[2], encoding: .utf8).split(separator: "\n")
        .map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
    let reportURL = URL(fileURLWithPath: arguments[3])
    let repeatIndex = arguments.firstIndex(of: "--repeat")
    let repeats = repeatIndex.flatMap { Int(arguments[$0 + 1]) } ?? 1
    let decisionsURL = arguments.count > 4 && !arguments[4].hasPrefix("--") ? URL(fileURLWithPath: arguments[4]) : nil

    let initial = footprint().current
    // Hashing and compiling touch every byte, which the extension never does. Run --prepare
    // once in its own process so memory runs measure load and inference alone.
    let preparing = arguments.contains("--prepare")
    if preparing { try TransformerClassifierLoader.prepareDownloadedModel(in: directory, validatesRuntime: false) }
    guard let installed = TransformerModelStore.model(in: directory, validateChecksums: preparing) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let clock = ContinuousClock()
    let loadStarted = clock.now
    let tokenizer = try BPETokenizer(tokenizerURL: installed.tokenizerURL,
        configuration: BPETokenizer.Configuration(maxSequenceLength: installed.manifest.maxSequenceLength))
    let classifier = try TransformerTextClassifier(modelURL: TransformerModelStore.compiledModelURL(in: directory),
        tokenizer: tokenizer, labels: installed.manifest.labels, confidenceThreshold: 0.5,
        computeUnits: installed.manifest.runtimeProfile.computeUnits, embeddingURL: installed.embeddingURL,
        routing: installed.manifest.routing)
    let loadMilliseconds = milliseconds(loadStarted.duration(to: clock.now))
    let afterLoad = footprint().current

    let engine = MessageFilterEngine(classicClassifier: classifier, transformerLoader: Loader(classifier: classifier),
                                     transformerDeviceSupport: .supported)
    let configuration = FilterConfigurationSnapshot(generation: 1, selectedVariant: .transformer,
        modelArtifactIdentity: installed.manifest.artifactIdentity, rules: [], categoryMappings: [:])
    var latencies: [Double] = []
    var failures = 0
    var output = Data()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for pass in 0..<max(repeats, 1) {
        for (index, row) in rows.enumerated() {
            let started = clock.now
            let result = await engine.classify(MessageFilterRequest(sender: nil, body: row.text), configuration: configuration)
            latencies.append(milliseconds(started.duration(to: clock.now)))
            if result.fallbackReason != .none { failures += 1 }
            if pass == 0, decisionsURL != nil {
                let raw = classifier.classify(sender: nil, body: row.text)
                output.append(try encoder.encode(Decision(index: index, text: row.text, label: row.label, rawPrediction: raw.labelID,
                    confidence: raw.confidence, engineLabel: result.decision.labelID, engineAction: result.systemAction,
                    engineSubAction: result.systemSubAction, fallbackReason: result.fallbackReason)))
                output.append(0x0a)
            }
        }
    }
    if let decisionsURL { try output.write(to: decisionsURL, options: .atomic) }
    let sorted = latencies.sorted()
    let final = footprint()
    let report = Report(version: installed.manifest.version, releaseSequence: installed.manifest.releaseSequence,
        routed: installed.manifest.routing != nil, contractAccepted: TransformerSignalReleaseContract.accepts(installed.manifest),
        downloadBytes: installed.manifest.downloadBytes, inferences: latencies.count, failures: failures,
        initialFootprint: initial, afterLoadFootprint: afterLoad, finalFootprint: final.current, peakFootprint: final.peak,
        loadMilliseconds: loadMilliseconds, p50Milliseconds: sorted[sorted.count / 2],
        p95Milliseconds: sorted[sorted.count * 95 / 100], maxMilliseconds: sorted.last ?? 0)
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try encoder.encode(report).write(to: reportURL, options: .atomic)
}

try await run()
