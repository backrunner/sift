#if canImport(Testing)
import Foundation
import MessageFilterCore
import MessageFilterExtensionKit
import Testing

@Test
func diagnosticLogsSeparateRegularAndDeveloperDetailsWithoutMessageContent() throws {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SiftDiagnosticTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let store = MessageFilterDiagnosticLogStore(directoryURL: directoryURL)
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 3,
        sha256: "signal-release-3"
    )
    let event = MessageFilterDiagnosticEvent(
        artifactIdentity: identity,
        latencyBucket: .under500Milliseconds,
        fallbackReason: .none,
        requestedArtifactIdentity: identity,
        physicalFootprintBeforeBytes: 100_000,
        physicalFootprintBytes: 123_456,
        signalTiming: SignalModelTimingMetrics(
            accessKind: .coldLoad,
            totalLoadMilliseconds: 320,
            queryWaitMilliseconds: 325,
            inferenceMilliseconds: 28,
            loadPhases: SignalModelLoadPhaseMetrics(
                artifactResolutionMilliseconds: 2,
                tokenizerMilliseconds: 18,
                modelInitializationMilliseconds: 240
            ),
            idleRetentionMilliseconds: 15_000
        ),
        selectedVariant: .transformer,
        configurationGeneration: 42,
        executionPath: .signal,
        decisionLabelID: "promotion",
        decisionConfidence: 0.98,
        decisionSource: .model,
        systemAction: .promotion,
        systemSubAction: .promotionalOffers
    )

    #expect(store.record(event, includesDetails: false))
    #expect(store.record(event, includesDetails: true))
    let data = try store.exportData(metadata: diagnosticExportMetadata(identity: identity))
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("sender") == false)
    #expect(text.contains("body") == false)
    #expect(text.contains("messageBody") == false)

    let records = try decodeLogRecords(from: data)
    try #require(records.count == 2)
    #expect(records[0].details == nil)
    #expect(records[1].details?.requestedArtifactIdentity == identity)
    #expect(records[1].details?.decisionLabelID == "promotion")
    #expect(records[1].details?.decisionSource == .model)
    #expect(records[1].details?.physicalFootprintBeforeBytes == 100_000)
    #expect(records[1].details?.physicalFootprintBytes == 123_456)
    #expect(records[1].signalTiming?.accessKind == .coldLoad)
    #expect(records[1].signalTiming?.totalLoadMilliseconds == 320)
    #expect(records[1].signalTiming?.loadPhases?.modelInitializationMilliseconds == 240)
}

@Test
func signalCacheReleaseLogsAreExportableWithoutMessageContent() throws {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SiftSignalReleaseLogTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let store = MessageFilterDiagnosticLogStore(directoryURL: directoryURL)
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 3,
        sha256: "signal-release-3"
    )

    #expect(store.record(
        SignalModelCacheReleaseEvent(
            artifactIdentity: identity,
            reason: .memoryPressure,
            residencyMilliseconds: 4_200,
            totalLoadMilliseconds: 380,
            loadPhases: SignalModelLoadPhaseMetrics(
                artifactResolutionMilliseconds: 3,
                tokenizerMilliseconds: 17,
                modelInitializationMilliseconds: 280
            )
        ),
        physicalFootprintBytes: 150_000_000
    ))

    let data = try store.exportData(metadata: diagnosticExportMetadata(identity: identity))
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("sender") == false)
    #expect(text.contains("body") == false)
    #expect(text.contains("messageBody") == false)

    let records = try decodeCacheReleaseRecords(from: data)
    let record = try #require(records.first)
    #expect(record.artifactIdentity == identity)
    #expect(record.reason == .memoryPressure)
    #expect(record.residencyMilliseconds == 4_200)
    #expect(record.totalLoadMilliseconds == 380)
    #expect(record.loadPhases?.firstPredictionStrategy == .realMessage)
    #expect(record.physicalFootprintBytes == 150_000_000)
}

@Test
func signalInstallationPrimeTimingsAreExportableWithoutMessageContent() throws {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SiftSignalPrimeLogTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let store = MessageFilterDiagnosticLogStore(directoryURL: directoryURL)
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 3,
        sha256: "signal-release-3"
    )
    let metrics = SignalModelInstallationPrimeMetrics(
        artifactIdentity: identity,
        succeeded: true,
        totalMilliseconds: 410,
        tokenizerMilliseconds: 1,
        modelInitializationMilliseconds: 380,
        inferenceMilliseconds: 29
    )

    #expect(store.record(metrics))

    let data = try store.exportData(metadata: diagnosticExportMetadata(identity: identity))
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("sender") == false)
    #expect(text.contains("body") == false)
    let record = try #require(decodeInstallationPrimeRecords(from: data).first)
    #expect(record.metrics == metrics)
}

@Test
func diagnosticLogsRotateAndRetainTheNewestEvents() throws {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SiftDiagnosticRotationTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let store = MessageFilterDiagnosticLogStore(
        directoryURL: directoryURL,
        maximumFileSizeBytes: 1_024,
        archivedFileCount: 2
    )

    for index in 0..<40 {
        let event = MessageFilterDiagnosticEvent(
            artifactIdentity: .classic,
            latencyBucket: .under150Milliseconds,
            fallbackReason: .none,
            errorCode: "event-\(index)",
            selectedVariant: .classic,
            executionPath: .classic
        )
        #expect(store.record(event, includesDetails: false))
    }

    #expect(FileManager.default.fileExists(
        atPath: directoryURL.appendingPathComponent("message-filter.1.jsonl").path
    ))
    #expect(FileManager.default.fileExists(
        atPath: directoryURL.appendingPathComponent("message-filter.2.jsonl").path
    ))
    #expect(FileManager.default.fileExists(
        atPath: directoryURL.appendingPathComponent("message-filter.3.jsonl").path
    ) == false)

    let data = try store.exportData(metadata: diagnosticExportMetadata(identity: .classic))
    let records = try decodeLogRecords(from: data)
    #expect(records.isEmpty == false)
    #expect(records.count < 40)
    #expect(records.last?.errorCode == "event-39")
}

private func diagnosticExportMetadata(
    identity: ModelArtifactIdentity
) -> MessageFilterDiagnosticExportMetadata {
    MessageFilterDiagnosticExportMetadata(
        appVersion: "1.4",
        appBuild: "18",
        operatingSystemVersion: "test",
        developerModeEnabled: true,
        appGroupContainerAvailable: true,
        selectedVariant: identity.variant,
        configurationGeneration: 1,
        configuredArtifactIdentity: identity,
        installedTransformerVersion: identity.variant == .transformer ? "test-signal" : nil,
        installedTransformerIdentity: identity.variant == .transformer ? identity : nil,
        ruleCount: 0,
        categoryMappingCount: 0,
        transformerDeviceSupportStatus: .supported,
        transformerDeviceSupportReason: nil,
        performanceEvidence: MessageFilterPerformanceEvidenceSnapshot()
    )
}

private func decodeLogRecords(from data: Data) throws -> [MessageFilterDiagnosticLogRecord] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try data
        .split(separator: 0x0A)
        .compactMap { line in
            let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            guard object?["recordType"] as? String == "message_filter_event" else {
                return nil
            }
            return try decoder.decode(MessageFilterDiagnosticLogRecord.self, from: Data(line))
        }
}

private func decodeCacheReleaseRecords(from data: Data) throws -> [SignalModelCacheReleaseLogRecord] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try data
        .split(separator: 0x0A)
        .compactMap { line in
            let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            guard object?["recordType"] as? String == "signal_model_cache_release" else {
                return nil
            }
            return try decoder.decode(SignalModelCacheReleaseLogRecord.self, from: Data(line))
        }
}

private func decodeInstallationPrimeRecords(
    from data: Data
) throws -> [SignalModelInstallationPrimeLogRecord] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try data
        .split(separator: 0x0A)
        .compactMap { line in
            let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            guard object?["recordType"] as? String == "signal_model_installation_prime" else {
                return nil
            }
            return try decoder.decode(SignalModelInstallationPrimeLogRecord.self, from: Data(line))
        }
}
#endif
