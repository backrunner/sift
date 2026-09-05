import Foundation
import MessageFilterCore

#if canImport(Darwin)
import Darwin
#endif

#if canImport(OSLog)
import OSLog
#endif

#if os(iOS)
import os
#endif

public enum MessageFilterLatencyBucket: String, Codable, Hashable, Sendable {
    case under150Milliseconds
    case under250Milliseconds
    case under500Milliseconds
    case under600Milliseconds
    case under750Milliseconds
    case under900Milliseconds
    case under1000Milliseconds
    case under2000Milliseconds
    case under3000Milliseconds
    case under5000Milliseconds
    case under6000Milliseconds
    /// Retained so previously persisted schema-v1 evidence remains decodable.
    case atLeast1000Milliseconds
    case atLeast6000Milliseconds

    public init(elapsed: Duration) {
        if elapsed < .milliseconds(150) {
            self = .under150Milliseconds
        } else if elapsed < .milliseconds(250) {
            self = .under250Milliseconds
        } else if elapsed < .milliseconds(500) {
            self = .under500Milliseconds
        } else if elapsed < .milliseconds(600) {
            self = .under600Milliseconds
        } else if elapsed < .milliseconds(750) {
            self = .under750Milliseconds
        } else if elapsed < .milliseconds(900) {
            self = .under900Milliseconds
        } else if elapsed < .seconds(1) {
            self = .under1000Milliseconds
        } else if elapsed < .seconds(2) {
            self = .under2000Milliseconds
        } else if elapsed < .seconds(3) {
            self = .under3000Milliseconds
        } else if elapsed < .seconds(5) {
            self = .under5000Milliseconds
        } else if elapsed < .seconds(6) {
            self = .under6000Milliseconds
        } else {
            self = .atLeast6000Milliseconds
        }
    }
}

public struct MessageFilterDiagnosticEvent: Codable, Hashable, Sendable {
    public let requestID: UUID?
    public let processIdentifier: Int32?
    public let requestedArtifactIdentity: ModelArtifactIdentity
    public let artifactIdentity: ModelArtifactIdentity
    public let latencyBucket: MessageFilterLatencyBucket
    public let fallbackReason: MessageFilterFallbackReason
    public let errorCode: String?
    public let isColdStart: Bool
    public let physicalFootprintBeforeBytes: UInt64
    public let physicalFootprintBytes: UInt64
    public let signalTiming: SignalModelTimingMetrics?
    public let selectedVariant: ModelVariant
    public let configurationGeneration: UInt64
    public let executionPath: MessageFilterExecutionPath
    public let decisionLabelID: String?
    public let decisionConfidence: Double?
    public let decisionSource: ClassificationSource?
    public let systemAction: SystemAction?
    public let systemSubAction: SystemSubAction?
    public let appGroupContainerAvailable: Bool

    public init(
        artifactIdentity: ModelArtifactIdentity,
        latencyBucket: MessageFilterLatencyBucket,
        fallbackReason: MessageFilterFallbackReason,
        errorCode: String? = nil,
        requestedArtifactIdentity: ModelArtifactIdentity? = nil,
        isColdStart: Bool = false,
        physicalFootprintBeforeBytes: UInt64 = 0,
        physicalFootprintBytes: UInt64 = 0,
        signalTiming: SignalModelTimingMetrics? = nil,
        selectedVariant: ModelVariant? = nil,
        configurationGeneration: UInt64 = 0,
        executionPath: MessageFilterExecutionPath? = nil,
        decisionLabelID: String? = nil,
        decisionConfidence: Double? = nil,
        decisionSource: ClassificationSource? = nil,
        systemAction: SystemAction? = nil,
        systemSubAction: SystemSubAction? = nil,
        appGroupContainerAvailable: Bool = true,
        requestID: UUID? = nil,
        processIdentifier: Int32? = nil
    ) {
        self.requestID = requestID
        self.processIdentifier = processIdentifier
        let requestedArtifactIdentity = requestedArtifactIdentity ?? artifactIdentity
        self.requestedArtifactIdentity = requestedArtifactIdentity
        self.artifactIdentity = artifactIdentity
        self.latencyBucket = latencyBucket
        self.fallbackReason = fallbackReason
        self.errorCode = errorCode
        self.isColdStart = isColdStart
        self.physicalFootprintBeforeBytes = physicalFootprintBeforeBytes
        self.physicalFootprintBytes = physicalFootprintBytes
        self.signalTiming = signalTiming
        self.selectedVariant = selectedVariant ?? requestedArtifactIdentity.variant
        self.configurationGeneration = configurationGeneration
        self.executionPath = executionPath
            ?? (artifactIdentity.variant == .transformer ? .signal : .classic)
        self.decisionLabelID = decisionLabelID
        self.decisionConfidence = decisionConfidence
        self.decisionSource = decisionSource
        self.systemAction = systemAction
        self.systemSubAction = systemSubAction
        self.appGroupContainerAvailable = appGroupContainerAvailable
    }
}

public final class MessageFilterSessionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var hasHandledQuery = false

    public init() {}

    public func beginQuery() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let isColdStart = !hasHandledQuery
        hasHandledQuery = true
        return isColdStart
    }
}

public struct MessageFilterReleasePerformanceEvidence: Codable, Hashable, Sendable {
    public let requestedVariant: ModelVariant
    public let requestedArtifactIdentity: ModelArtifactIdentity
    public var coldRunCount: Int
    public var warmQueryCount: Int
    public var coldLatencyBuckets: [String: Int]
    public var warmLatencyBuckets: [String: Int]
    public var actualArtifactCounts: [String: Int]
    public var executionPathCounts: [String: Int]
    public var fallbackCounts: [String: Int]
    public var errorCounts: [String: Int]
    public var watchdogCount: Int
    public var firstPhysicalFootprintBytes: UInt64
    public var latestPhysicalFootprintBytes: UInt64
    public var peakPhysicalFootprintBytes: UInt64

    public var memoryDriftBytes: Int64 {
        Self.signedDifference(latestPhysicalFootprintBytes, firstPhysicalFootprintBytes)
    }

    public init(
        requestedVariant: ModelVariant,
        requestedArtifactIdentity: ModelArtifactIdentity
    ) {
        self.requestedVariant = requestedVariant
        self.requestedArtifactIdentity = requestedArtifactIdentity
        self.coldRunCount = 0
        self.warmQueryCount = 0
        self.coldLatencyBuckets = [:]
        self.warmLatencyBuckets = [:]
        self.actualArtifactCounts = [:]
        self.executionPathCounts = [:]
        self.fallbackCounts = [:]
        self.errorCounts = [:]
        self.watchdogCount = 0
        self.firstPhysicalFootprintBytes = 0
        self.latestPhysicalFootprintBytes = 0
        self.peakPhysicalFootprintBytes = 0
    }

    fileprivate mutating func record(_ event: MessageFilterDiagnosticEvent) {
        if event.isColdStart {
            coldRunCount += 1
            coldLatencyBuckets[event.latencyBucket.rawValue, default: 0] += 1
        } else {
            warmQueryCount += 1
            warmLatencyBuckets[event.latencyBucket.rawValue, default: 0] += 1
        }
        executionPathCounts[event.executionPath.rawValue, default: 0] += 1
        if event.executionPath == .classic || event.executionPath == .signal {
            actualArtifactCounts[Self.identityKey(event.artifactIdentity), default: 0] += 1
        }
        fallbackCounts[event.fallbackReason.rawValue, default: 0] += 1
        if let errorCode = event.errorCode {
            errorCounts[errorCode, default: 0] += 1
            if errorCode == "handler_watchdog" {
                watchdogCount += 1
            }
        }
        guard event.physicalFootprintBytes > 0 else {
            return
        }
        if firstPhysicalFootprintBytes == 0 {
            firstPhysicalFootprintBytes = event.physicalFootprintBytes
        }
        latestPhysicalFootprintBytes = event.physicalFootprintBytes
        peakPhysicalFootprintBytes = max(peakPhysicalFootprintBytes, event.physicalFootprintBytes)
    }

    fileprivate static func identityKey(_ identity: ModelArtifactIdentity) -> String {
        [
            identity.variant.rawValue,
            identity.modelABI,
            String(identity.releaseSequence),
            identity.sha256,
        ].joined(separator: "|")
    }

    private static func signedDifference(_ lhs: UInt64, _ rhs: UInt64) -> Int64 {
        if lhs >= rhs {
            return Int64(min(lhs - rhs, UInt64(Int64.max)))
        }
        return -Int64(min(rhs - lhs, UInt64(Int64.max)))
    }
}

public struct MessageFilterPerformanceEvidenceSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public var releases: [String: MessageFilterReleasePerformanceEvidence]
    public var latestEvent: MessageFilterDiagnosticEvent?

    public init(
        schemaVersion: Int = MessageFilterPerformanceEvidenceSnapshot.currentSchemaVersion,
        releases: [String: MessageFilterReleasePerformanceEvidence] = [:],
        latestEvent: MessageFilterDiagnosticEvent? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.releases = releases
        self.latestEvent = latestEvent
    }
}

public final class MessageFilterPerformanceEvidenceStore: @unchecked Sendable {
    public static let defaultsKey = "Sift.messageFilterPerformanceEvidence.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: ModelSelectionStore.appGroupIdentifier)
            ?? .standard
    }

    public func record(_ event: MessageFilterDiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = loadUnlocked()
        let key = [
            event.selectedVariant.rawValue,
            MessageFilterReleasePerformanceEvidence.identityKey(event.requestedArtifactIdentity),
        ].joined(separator: "|")
        var release = snapshot.releases[key]
            ?? MessageFilterReleasePerformanceEvidence(
                requestedVariant: event.selectedVariant,
                requestedArtifactIdentity: event.requestedArtifactIdentity
            )
        release.record(event)
        snapshot.releases[key] = release
        snapshot.latestEvent = event
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public func snapshot() -> MessageFilterPerformanceEvidenceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func loadUnlocked() -> MessageFilterPerformanceEvidenceSnapshot {
        guard
            let data = defaults.data(forKey: Self.defaultsKey),
            let snapshot = try? JSONDecoder().decode(MessageFilterPerformanceEvidenceSnapshot.self, from: data),
            snapshot.schemaVersion == MessageFilterPerformanceEvidenceSnapshot.currentSchemaVersion
        else {
            return MessageFilterPerformanceEvidenceSnapshot()
        }
        return snapshot
    }
}

public struct MessageFilterMemorySnapshot: Codable, Hashable, Sendable {
    public let physicalFootprintBytes: UInt64
    public let processPeakPhysicalFootprintBytes: UInt64
    public let availableMemoryBytes: UInt64?

    public init(
        physicalFootprintBytes: UInt64,
        processPeakPhysicalFootprintBytes: UInt64,
        availableMemoryBytes: UInt64?
    ) {
        self.physicalFootprintBytes = physicalFootprintBytes
        self.processPeakPhysicalFootprintBytes = processPeakPhysicalFootprintBytes
        self.availableMemoryBytes = availableMemoryBytes
    }
}

public enum MessageFilterProcessMetrics {
    public static func currentPhysicalFootprintBytes() -> UInt64 {
        memorySnapshot().physicalFootprintBytes
    }

    public static func memorySnapshot() -> MessageFilterMemorySnapshot {
        var footprint: UInt64 = 0
        var peak: UInt64 = 0
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            footprint = info.phys_footprint
            peak = UInt64(max(info.ledger_phys_footprint_peak, 0))
        }
        #endif
        #if os(iOS)
        // A point-in-time dirty-memory allowance, not total device free RAM.
        // Zero can also mean the API has no applicable app limit.
        let available: UInt64? = UInt64(os_proc_available_memory())
        #else
        let available: UInt64? = nil
        #endif
        return MessageFilterMemorySnapshot(
            physicalFootprintBytes: footprint,
            processPeakPhysicalFootprintBytes: peak,
            availableMemoryBytes: available
        )
    }
}

public protocol MessageFilterDiagnosticsRecording: Sendable {
    func record(_ event: MessageFilterDiagnosticEvent)
}

public struct MessageFilterOSLogDiagnosticsRecorder: MessageFilterDiagnosticsRecording {
    #if canImport(OSLog)
    private let logger = Logger(subsystem: "com.alkinum.sift.MessageFilterExtension", category: "filter")
    #endif
    private let performanceStore: MessageFilterPerformanceEvidenceStore
    private let diagnosticLogStore: MessageFilterDiagnosticLogStore

    public init(
        performanceStore: MessageFilterPerformanceEvidenceStore = MessageFilterPerformanceEvidenceStore(),
        diagnosticLogStore: MessageFilterDiagnosticLogStore = MessageFilterDiagnosticLogStore()
    ) {
        self.performanceStore = performanceStore
        self.diagnosticLogStore = diagnosticLogStore
    }

    public func record(_ event: MessageFilterDiagnosticEvent) {
        performanceStore.record(event)
        let detailedLoggingEnabled = DeveloperModeStore.isEnabled()
        let persisted = diagnosticLogStore.record(event, includesDetails: detailedLoggingEnabled)
        #if canImport(OSLog)
        if !persisted {
            logger.error("diagnostic_write_failed record=message_filter_event")
        }
        if detailedLoggingEnabled {
            let actualArtifactIdentity: ModelArtifactIdentity? = switch event.executionPath {
            case .classic, .signal:
                event.artifactIdentity
            case .rule, .noDecision:
                nil
            }
            logger.notice(
                "selected=\(event.selectedVariant.rawValue, privacy: .public) path=\(event.executionPath.rawValue, privacy: .public) requested_abi=\(event.requestedArtifactIdentity.modelABI, privacy: .public) requested_sequence=\(event.requestedArtifactIdentity.releaseSequence) requested_sha=\(event.requestedArtifactIdentity.sha256, privacy: .public) actual_abi=\(actualArtifactIdentity?.modelABI ?? "none", privacy: .public) actual_sequence=\(actualArtifactIdentity?.releaseSequence ?? -1) actual_sha=\(actualArtifactIdentity?.sha256 ?? "none", privacy: .public) generation=\(event.configurationGeneration) label=\(event.decisionLabelID ?? "none", privacy: .public) confidence=\(event.decisionConfidence ?? -1) source=\(event.decisionSource?.rawValue ?? "none", privacy: .public) action=\(event.systemAction?.rawValue ?? "none", privacy: .public) sub_action=\(event.systemSubAction?.rawValue ?? "none", privacy: .public) latency=\(event.latencyBucket.rawValue, privacy: .public) cold=\(event.isColdStart) signal_access=\(event.signalTiming?.accessKind.rawValue ?? "none", privacy: .public) signal_load_ms=\(event.signalTiming?.totalLoadMilliseconds ?? -1) signal_wait_ms=\(event.signalTiming?.queryWaitMilliseconds ?? -1) signal_inference_ms=\(event.signalTiming?.inferenceMilliseconds ?? -1) artifact_ms=\(event.signalTiming?.loadPhases?.artifactResolutionMilliseconds ?? -1) tokenizer_ms=\(event.signalTiming?.loadPhases?.tokenizerMilliseconds ?? -1) model_init_ms=\(event.signalTiming?.loadPhases?.modelInitializationMilliseconds ?? -1) first_prediction=\(event.signalTiming?.loadPhases?.firstPredictionStrategy.rawValue ?? "none", privacy: .public) fallback=\(event.fallbackReason.rawValue, privacy: .public) error=\(event.errorCode ?? "none", privacy: .public) footprint_before=\(event.physicalFootprintBeforeBytes) footprint_after=\(event.physicalFootprintBytes) app_group=\(event.appGroupContainerAvailable)"
            )
        } else {
            logger.notice(
                "selected=\(event.selectedVariant.rawValue, privacy: .public) path=\(event.executionPath.rawValue, privacy: .public) latency=\(event.latencyBucket.rawValue, privacy: .public) cold=\(event.isColdStart) signal_access=\(event.signalTiming?.accessKind.rawValue ?? "none", privacy: .public) signal_load_ms=\(event.signalTiming?.totalLoadMilliseconds ?? -1) signal_wait_ms=\(event.signalTiming?.queryWaitMilliseconds ?? -1) signal_inference_ms=\(event.signalTiming?.inferenceMilliseconds ?? -1) fallback=\(event.fallbackReason.rawValue, privacy: .public) error=\(event.errorCode ?? "none", privacy: .public) app_group=\(event.appGroupContainerAvailable)"
            )
        }
        #endif
    }

    public func stageObserver(
        requestID: UUID,
        configuration: FilterConfigurationSnapshot
    ) -> MessageFilterStageObserver {
        let startedAt = ContinuousClock().now
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return { stage in
            // Logging must not leave autoreleased encoding/file objects alive
            // across the following model allocation.
            #if canImport(ObjectiveC)
            autoreleasepool {
                recordStage(stage, requestID: requestID, processIdentifier: processIdentifier,
                            bundleIdentifier: bundleIdentifier, appBuild: appBuild,
                            startedAt: startedAt, configuration: configuration)
            }
            #else
            recordStage(stage, requestID: requestID, processIdentifier: processIdentifier,
                        bundleIdentifier: bundleIdentifier, appBuild: appBuild,
                        startedAt: startedAt, configuration: configuration)
            #endif
        }
    }

    private func recordStage(
        _ stage: MessageFilterStage,
        requestID: UUID,
        processIdentifier: Int32,
        bundleIdentifier: String,
        appBuild: String,
        startedAt: ContinuousClock.Instant,
        configuration: FilterConfigurationSnapshot
    ) {
        let record = MessageFilterStageLogRecord(
            requestID: requestID,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            appBuild: appBuild,
            stage: stage,
            elapsedMilliseconds: Int(startedAt.duration(to: ContinuousClock().now) / .milliseconds(1)),
            configuration: configuration,
            memory: MessageFilterProcessMetrics.memorySnapshot()
        )
        #if canImport(OSLog)
        logger.notice(
            "request=\(requestID.uuidString, privacy: .public) pid=\(processIdentifier) stage=\(stage.rawValue, privacy: .public) elapsed_ms=\(record.elapsedMilliseconds) footprint=\(record.memory.physicalFootprintBytes) process_peak=\(record.memory.processPeakPhysicalFootprintBytes) available=\(record.memory.availableMemoryBytes ?? 0)"
        )
        #endif
        // Persist before the next expensive phase, so a process kill cannot
        // erase all evidence of an otherwise unfinished request.
        let persisted = diagnosticLogStore.record(record)
        #if canImport(OSLog)
        if !persisted {
            logger.error("diagnostic_write_failed record=message_filter_stage")
        }
        #endif
    }

    public func record(_ event: SignalModelCacheReleaseEvent) {
        let footprint = MessageFilterProcessMetrics.currentPhysicalFootprintBytes()
        diagnosticLogStore.record(event, physicalFootprintBytes: footprint)
        #if canImport(OSLog)
        logger.notice(
            "signal_cache_release reason=\(event.reason.rawValue, privacy: .public) abi=\(event.artifactIdentity.modelABI, privacy: .public) sequence=\(event.artifactIdentity.releaseSequence) residency_ms=\(event.residencyMilliseconds) signal_load_ms=\(event.totalLoadMilliseconds) artifact_ms=\(event.loadPhases?.artifactResolutionMilliseconds ?? -1) tokenizer_ms=\(event.loadPhases?.tokenizerMilliseconds ?? -1) model_init_ms=\(event.loadPhases?.modelInitializationMilliseconds ?? -1) first_prediction=\(event.loadPhases?.firstPredictionStrategy.rawValue ?? "none", privacy: .public) footprint=\(footprint)"
        )
        #endif
    }
}
