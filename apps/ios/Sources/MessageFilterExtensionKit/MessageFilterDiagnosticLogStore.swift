import Foundation
import MessageFilterCore

#if canImport(Darwin)
import Darwin
#endif

public struct MessageFilterDiagnosticLogDetails: Codable, Hashable, Sendable {
    public let configurationGeneration: UInt64
    public let requestedArtifactIdentity: ModelArtifactIdentity
    public let actualArtifactIdentity: ModelArtifactIdentity?
    public let decisionLabelID: String?
    public let decisionConfidence: Double?
    public let decisionSource: ClassificationSource?
    public let systemAction: SystemAction?
    public let systemSubAction: SystemSubAction?
    public let physicalFootprintBeforeBytes: UInt64
    public let physicalFootprintBytes: UInt64
}

public struct MessageFilterDiagnosticLogRecord: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public let recordType: String
    public let requestID: UUID?
    public let processIdentifier: Int32?
    public let schemaVersion: Int
    public let recordedAt: Date
    public let selectedVariant: ModelVariant
    public let actualVariant: ModelVariant?
    public let executionPath: MessageFilterExecutionPath
    public let latencyBucket: MessageFilterLatencyBucket
    public let fallbackReason: MessageFilterFallbackReason
    public let errorCode: String?
    public let isColdStart: Bool
    public let signalTiming: SignalModelTimingMetrics?
    public let appGroupContainerAvailable: Bool
    public let details: MessageFilterDiagnosticLogDetails?

    public init(
        event: MessageFilterDiagnosticEvent,
        recordedAt: Date = .now,
        includesDetails: Bool
    ) {
        self.recordType = "message_filter_event"
        self.requestID = event.requestID
        self.processIdentifier = event.processIdentifier
        self.schemaVersion = Self.currentSchemaVersion
        self.recordedAt = recordedAt
        self.selectedVariant = event.selectedVariant
        self.actualVariant = switch event.executionPath {
        case .classic:
            .classic
        case .signal:
            .transformer
        case .rule, .noDecision:
            nil
        }
        self.executionPath = event.executionPath
        self.latencyBucket = event.latencyBucket
        self.fallbackReason = event.fallbackReason
        self.errorCode = event.errorCode
        self.isColdStart = event.isColdStart
        self.signalTiming = event.signalTiming
        self.appGroupContainerAvailable = event.appGroupContainerAvailable
        self.details = includesDetails
            ? MessageFilterDiagnosticLogDetails(
                configurationGeneration: event.configurationGeneration,
                requestedArtifactIdentity: event.requestedArtifactIdentity,
                actualArtifactIdentity: event.executionPath == .rule || event.executionPath == .noDecision
                    ? nil : event.artifactIdentity,
                decisionLabelID: event.decisionLabelID,
                decisionConfidence: event.decisionConfidence,
                decisionSource: event.decisionSource,
                systemAction: event.systemAction,
                systemSubAction: event.systemSubAction,
                physicalFootprintBeforeBytes: event.physicalFootprintBeforeBytes,
                physicalFootprintBytes: event.physicalFootprintBytes
            )
            : nil
    }
}

public struct MessageFilterStageLogRecord: Codable, Hashable, Sendable {
    public let recordType: String
    public let schemaVersion: Int
    public let recordedAt: Date
    public let requestID: UUID
    public let processIdentifier: Int32
    public let bundleIdentifier: String
    public let appBuild: String
    public let stage: MessageFilterStage
    public let elapsedMilliseconds: Int
    public let selectedVariant: ModelVariant
    public let requestedArtifactIdentity: ModelArtifactIdentity
    public let configurationGeneration: UInt64
    public let memory: MessageFilterMemorySnapshot

    public init(
        requestID: UUID,
        processIdentifier: Int32,
        bundleIdentifier: String,
        appBuild: String,
        stage: MessageFilterStage,
        elapsedMilliseconds: Int,
        configuration: FilterConfigurationSnapshot,
        memory: MessageFilterMemorySnapshot,
        recordedAt: Date = .now
    ) {
        self.recordType = "message_filter_stage"
        self.schemaVersion = 1
        self.recordedAt = recordedAt
        self.requestID = requestID
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.appBuild = appBuild
        self.stage = stage
        self.elapsedMilliseconds = elapsedMilliseconds
        self.selectedVariant = configuration.selectedVariant
        self.requestedArtifactIdentity = configuration.modelArtifactIdentity
        self.configurationGeneration = configuration.generation
        self.memory = memory
    }
}

public struct SignalModelCacheReleaseLogRecord: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public let recordType: String
    public let schemaVersion: Int
    public let recordedAt: Date
    public let artifactIdentity: ModelArtifactIdentity
    public let reason: SignalModelCacheReleaseReason
    public let residencyMilliseconds: Int
    public let totalLoadMilliseconds: Int
    public let loadPhases: SignalModelLoadPhaseMetrics?
    public let physicalFootprintBytes: UInt64

    public init(
        event: SignalModelCacheReleaseEvent,
        physicalFootprintBytes: UInt64,
        recordedAt: Date = .now
    ) {
        self.recordType = "signal_model_cache_release"
        self.schemaVersion = Self.currentSchemaVersion
        self.recordedAt = recordedAt
        self.artifactIdentity = event.artifactIdentity
        self.reason = event.reason
        self.residencyMilliseconds = event.residencyMilliseconds
        self.totalLoadMilliseconds = event.totalLoadMilliseconds
        self.loadPhases = event.loadPhases
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

public struct SignalModelInstallationPrimeLogRecord: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let recordType: String
    public let schemaVersion: Int
    public let recordedAt: Date
    public let metrics: SignalModelInstallationPrimeMetrics

    public init(
        metrics: SignalModelInstallationPrimeMetrics,
        recordedAt: Date = .now
    ) {
        self.recordType = "signal_model_installation_prime"
        self.schemaVersion = Self.currentSchemaVersion
        self.recordedAt = recordedAt
        self.metrics = metrics
    }
}

public struct MessageFilterDiagnosticExportMetadata: Codable, Hashable, Sendable {
    public let recordType: String
    public let schemaVersion: Int
    public let generatedAt: Date
    public let appVersion: String
    public let appBuild: String
    public let operatingSystemVersion: String
    public let developerModeEnabled: Bool
    public let appGroupContainerAvailable: Bool
    public let selectedVariant: ModelVariant
    public let configurationGeneration: UInt64
    public let configuredArtifactIdentity: ModelArtifactIdentity
    public let installedTransformerVersion: String?
    public let installedTransformerIdentity: ModelArtifactIdentity?
    public let ruleCount: Int
    public let categoryMappingCount: Int
    public let transformerDeviceSupportStatus: TransformerDeviceSupport.Status
    public let transformerDeviceSupportReason: TransformerDeviceSupport.Reason?
    public let performanceEvidence: MessageFilterPerformanceEvidenceSnapshot

    public init(
        generatedAt: Date = .now,
        appVersion: String,
        appBuild: String,
        operatingSystemVersion: String,
        developerModeEnabled: Bool,
        appGroupContainerAvailable: Bool,
        selectedVariant: ModelVariant,
        configurationGeneration: UInt64,
        configuredArtifactIdentity: ModelArtifactIdentity,
        installedTransformerVersion: String?,
        installedTransformerIdentity: ModelArtifactIdentity?,
        ruleCount: Int,
        categoryMappingCount: Int,
        transformerDeviceSupportStatus: TransformerDeviceSupport.Status,
        transformerDeviceSupportReason: TransformerDeviceSupport.Reason?,
        performanceEvidence: MessageFilterPerformanceEvidenceSnapshot
    ) {
        self.recordType = "export_metadata"
        self.schemaVersion = 1
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.operatingSystemVersion = operatingSystemVersion
        self.developerModeEnabled = developerModeEnabled
        self.appGroupContainerAvailable = appGroupContainerAvailable
        self.selectedVariant = selectedVariant
        self.configurationGeneration = configurationGeneration
        self.configuredArtifactIdentity = configuredArtifactIdentity
        self.installedTransformerVersion = installedTransformerVersion
        self.installedTransformerIdentity = installedTransformerIdentity
        self.ruleCount = ruleCount
        self.categoryMappingCount = categoryMappingCount
        self.transformerDeviceSupportStatus = transformerDeviceSupportStatus
        self.transformerDeviceSupportReason = transformerDeviceSupportReason
        self.performanceEvidence = performanceEvidence
    }
}

/// A bounded JSONL store in the App Group container. `NSLock` protects callers
/// within one process and a `fcntl` lock coordinates the app and extension.
public final class MessageFilterDiagnosticLogStore: @unchecked Sendable {
    public static let defaultMaximumFileSizeBytes: UInt64 = 512 * 1_024
    public static let defaultArchivedFileCount = 3

    private static let directoryComponents = ["Library", "Caches", "Sift", "Diagnostics"]
    private static let activeFileName = "message-filter.jsonl"
    private static let lockFileName = ".message-filter.lock"

    private let directoryURL: URL?
    private let maximumFileSizeBytes: UInt64
    private let archivedFileCount: Int
    private static let processLock = NSLock()

    public init(
        directoryURL: URL? = MessageFilterDiagnosticLogStore.defaultDirectoryURL(),
        maximumFileSizeBytes: UInt64 = MessageFilterDiagnosticLogStore.defaultMaximumFileSizeBytes,
        archivedFileCount: Int = MessageFilterDiagnosticLogStore.defaultArchivedFileCount
    ) {
        self.directoryURL = directoryURL
        self.maximumFileSizeBytes = max(maximumFileSizeBytes, 1_024)
        self.archivedFileCount = max(archivedFileCount, 0)
    }

    public var isAvailable: Bool {
        directoryURL != nil
    }

    @discardableResult
    public func record(_ record: MessageFilterStageLogRecord) -> Bool {
        guard let directoryURL else { return false }
        do {
            var data = try Self.encoder().encode(record)
            data.append(0x0A)
            try withLockedDirectory(directoryURL) {
                try rotateIfNeeded(forAdditionalByteCount: data.count, in: directoryURL)
                try append(data, to: activeLogURL(in: directoryURL))
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func record(
        _ event: MessageFilterDiagnosticEvent,
        includesDetails: Bool
    ) -> Bool {
        guard let directoryURL else {
            return false
        }
        do {
            let record = MessageFilterDiagnosticLogRecord(
                event: event,
                includesDetails: includesDetails
            )
            var data = try Self.encoder().encode(record)
            data.append(0x0A)
            try withLockedDirectory(directoryURL) {
                try rotateIfNeeded(forAdditionalByteCount: data.count, in: directoryURL)
                try append(data, to: activeLogURL(in: directoryURL))
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func record(
        _ event: SignalModelCacheReleaseEvent,
        physicalFootprintBytes: UInt64
    ) -> Bool {
        guard let directoryURL else {
            return false
        }
        do {
            let record = SignalModelCacheReleaseLogRecord(
                event: event,
                physicalFootprintBytes: physicalFootprintBytes
            )
            var data = try Self.encoder().encode(record)
            data.append(0x0A)
            try withLockedDirectory(directoryURL) {
                try rotateIfNeeded(forAdditionalByteCount: data.count, in: directoryURL)
                try append(data, to: activeLogURL(in: directoryURL))
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func record(_ metrics: SignalModelInstallationPrimeMetrics) -> Bool {
        guard let directoryURL else {
            return false
        }
        do {
            let record = SignalModelInstallationPrimeLogRecord(metrics: metrics)
            var data = try Self.encoder().encode(record)
            data.append(0x0A)
            try withLockedDirectory(directoryURL) {
                try rotateIfNeeded(forAdditionalByteCount: data.count, in: directoryURL)
                try append(data, to: activeLogURL(in: directoryURL))
            }
            return true
        } catch {
            return false
        }
    }

    public func exportData(metadata: MessageFilterDiagnosticExportMetadata) throws -> Data {
        var result = try Self.encoder().encode(metadata)
        result.append(0x0A)
        guard let directoryURL else {
            return result
        }
        return try withLockedDirectory(directoryURL) {
            for archiveIndex in stride(from: archivedFileCount, through: 1, by: -1) {
                try appendFileIfPresent(archiveURL(archiveIndex, in: directoryURL), to: &result)
            }
            try appendFileIfPresent(activeLogURL(in: directoryURL), to: &result)
            return result
        }
    }

    public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL? {
        guard var directory = ModelSelectionStore.sharedContainerURL(fileManager: fileManager) else {
            return nil
        }
        for component in directoryComponents {
            directory.appendPathComponent(component, isDirectory: true)
        }
        return directory
    }

    private func withLockedDirectory<T>(
        _ directoryURL: URL,
        operation: () throws -> T
    ) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectoryURL = directoryURL
        try? mutableDirectoryURL.setResourceValues(resourceValues)

        #if canImport(Darwin)
        let lockURL = directoryURL.appendingPathComponent(Self.lockFileName, isDirectory: false)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw Self.posixError()
        }
        defer { Darwin.close(descriptor) }
        var fileLock = flock()
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        while Darwin.fcntl(descriptor, F_SETLKW, &fileLock) == -1 {
            guard errno == EINTR else {
                throw Self.posixError()
            }
        }
        defer {
            fileLock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
        }
        #endif

        return try operation()
    }

    private func rotateIfNeeded(
        forAdditionalByteCount additionalByteCount: Int,
        in directoryURL: URL
    ) throws {
        let activeURL = activeLogURL(in: directoryURL)
        let attributes = try? FileManager.default.attributesOfItem(atPath: activeURL.path)
        let currentSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard currentSize + UInt64(additionalByteCount) > maximumFileSizeBytes else {
            return
        }
        guard FileManager.default.fileExists(atPath: activeURL.path) else {
            return
        }
        if archivedFileCount == 0 {
            try FileManager.default.removeItem(at: activeURL)
            return
        }

        let oldestArchiveURL = archiveURL(archivedFileCount, in: directoryURL)
        if FileManager.default.fileExists(atPath: oldestArchiveURL.path) {
            try FileManager.default.removeItem(at: oldestArchiveURL)
        }
        if archivedFileCount > 1 {
            for archiveIndex in stride(from: archivedFileCount - 1, through: 1, by: -1) {
                let sourceURL = archiveURL(archiveIndex, in: directoryURL)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    continue
                }
                try FileManager.default.moveItem(
                    at: sourceURL,
                    to: archiveURL(archiveIndex + 1, in: directoryURL)
                )
            }
        }
        try FileManager.default.moveItem(at: activeURL, to: archiveURL(1, in: directoryURL))
    }

    private func append(_ data: Data, to fileURL: URL) throws {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func appendFileIfPresent(_ fileURL: URL, to result: inout Data) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        let fileData = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        result.append(fileData)
        if result.last != 0x0A {
            result.append(0x0A)
        }
    }

    private func activeLogURL(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(Self.activeFileName, isDirectory: false)
    }

    private func archiveURL(_ index: Int, in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent("message-filter.\(index).jsonl", isDirectory: false)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    #if canImport(Darwin)
    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    #endif
}
