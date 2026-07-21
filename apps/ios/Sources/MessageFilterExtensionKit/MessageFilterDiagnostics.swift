import Foundation
import MessageFilterCore

#if canImport(Darwin)
import Darwin
#endif

#if canImport(OSLog)
import OSLog
#endif

public enum MessageFilterLatencyBucket: String, Codable, Hashable, Sendable {
    case under150Milliseconds
    case under250Milliseconds
    case under500Milliseconds
    case under600Milliseconds
    case under750Milliseconds
    case under900Milliseconds
    case under1000Milliseconds
    case atLeast1000Milliseconds

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
        } else {
            self = .atLeast1000Milliseconds
        }
    }
}

public struct MessageFilterDiagnosticEvent: Codable, Hashable, Sendable {
    public let requestedArtifactIdentity: ModelArtifactIdentity
    public let artifactIdentity: ModelArtifactIdentity
    public let latencyBucket: MessageFilterLatencyBucket
    public let fallbackReason: MessageFilterFallbackReason
    public let errorCode: String?
    public let isColdStart: Bool
    public let physicalFootprintBytes: UInt64

    public init(
        artifactIdentity: ModelArtifactIdentity,
        latencyBucket: MessageFilterLatencyBucket,
        fallbackReason: MessageFilterFallbackReason,
        errorCode: String? = nil,
        requestedArtifactIdentity: ModelArtifactIdentity? = nil,
        isColdStart: Bool = false,
        physicalFootprintBytes: UInt64 = 0
    ) {
        self.requestedArtifactIdentity = requestedArtifactIdentity ?? artifactIdentity
        self.artifactIdentity = artifactIdentity
        self.latencyBucket = latencyBucket
        self.fallbackReason = fallbackReason
        self.errorCode = errorCode
        self.isColdStart = isColdStart
        self.physicalFootprintBytes = physicalFootprintBytes
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
    public let requestedArtifactIdentity: ModelArtifactIdentity
    public var coldRunCount: Int
    public var warmQueryCount: Int
    public var coldLatencyBuckets: [String: Int]
    public var warmLatencyBuckets: [String: Int]
    public var actualArtifactCounts: [String: Int]
    public var fallbackCounts: [String: Int]
    public var errorCounts: [String: Int]
    public var watchdogCount: Int
    public var firstPhysicalFootprintBytes: UInt64
    public var latestPhysicalFootprintBytes: UInt64
    public var peakPhysicalFootprintBytes: UInt64

    public var memoryDriftBytes: Int64 {
        Self.signedDifference(latestPhysicalFootprintBytes, firstPhysicalFootprintBytes)
    }

    public init(requestedArtifactIdentity: ModelArtifactIdentity) {
        self.requestedArtifactIdentity = requestedArtifactIdentity
        self.coldRunCount = 0
        self.warmQueryCount = 0
        self.coldLatencyBuckets = [:]
        self.warmLatencyBuckets = [:]
        self.actualArtifactCounts = [:]
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
        actualArtifactCounts[Self.identityKey(event.artifactIdentity), default: 0] += 1
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
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var releases: [String: MessageFilterReleasePerformanceEvidence]

    public init(
        schemaVersion: Int = MessageFilterPerformanceEvidenceSnapshot.currentSchemaVersion,
        releases: [String: MessageFilterReleasePerformanceEvidence] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.releases = releases
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
        let key = MessageFilterReleasePerformanceEvidence.identityKey(event.requestedArtifactIdentity)
        var release = snapshot.releases[key]
            ?? MessageFilterReleasePerformanceEvidence(requestedArtifactIdentity: event.requestedArtifactIdentity)
        release.record(event)
        snapshot.releases[key] = release
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

public enum MessageFilterProcessMetrics {
    public static func currentPhysicalFootprintBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
        #else
        return 0
        #endif
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

    public init(performanceStore: MessageFilterPerformanceEvidenceStore = MessageFilterPerformanceEvidenceStore()) {
        self.performanceStore = performanceStore
    }

    public func record(_ event: MessageFilterDiagnosticEvent) {
        performanceStore.record(event)
        #if canImport(OSLog)
        logger.notice(
            "requested_sequence=\(event.requestedArtifactIdentity.releaseSequence) variant=\(event.artifactIdentity.variant.rawValue, privacy: .public) abi=\(event.artifactIdentity.modelABI, privacy: .public) sequence=\(event.artifactIdentity.releaseSequence) sha=\(event.artifactIdentity.sha256, privacy: .public) latency=\(event.latencyBucket.rawValue, privacy: .public) cold=\(event.isColdStart) fallback=\(event.fallbackReason.rawValue, privacy: .public) error=\(event.errorCode ?? "none", privacy: .public)"
        )
        #endif
    }
}
