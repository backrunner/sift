import Foundation

public struct QuantizationCandidateReport: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let profileID: String
    public let artifactSHA256: String
    public let downloadBytes: Int64
    public let metrics: QuantizationQualityMetrics
    public let messageFilterActions: QuantizationMessageFilterMetrics
    public let deviceMetrics: QuantizationDeviceMetrics

    public init(
        schemaVersion: Int = 1,
        profileID: String,
        artifactSHA256: String,
        downloadBytes: Int64,
        metrics: QuantizationQualityMetrics,
        messageFilterActions: QuantizationMessageFilterMetrics,
        deviceMetrics: QuantizationDeviceMetrics
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.artifactSHA256 = artifactSHA256
        self.downloadBytes = downloadBytes
        self.metrics = metrics
        self.messageFilterActions = messageFilterActions
        self.deviceMetrics = deviceMetrics
    }
}

public struct QuantizationQualityMetrics: Codable, Hashable, Sendable {
    public let fixedAccuracy: Double
    public let promotionAccuracy: Double
    public let fp16Top1Agreement: Double
    public let probabilitiesFinite: Bool
    public let probabilitySumsValid: Bool
    public let languageAccuracy: [String: Double]

    public init(
        fixedAccuracy: Double,
        promotionAccuracy: Double,
        fp16Top1Agreement: Double,
        probabilitiesFinite: Bool,
        probabilitySumsValid: Bool,
        languageAccuracy: [String: Double]
    ) {
        self.fixedAccuracy = fixedAccuracy
        self.promotionAccuracy = promotionAccuracy
        self.fp16Top1Agreement = fp16Top1Agreement
        self.probabilitiesFinite = probabilitiesFinite
        self.probabilitySumsValid = probabilitySumsValid
        self.languageAccuracy = languageAccuracy
    }
}

public struct QuantizationMessageFilterMetrics: Codable, Hashable, Sendable {
    public let fixedAccuracy: Double
    public let promotionAccuracy: Double
    public let benignOrTransactionToJunk: Int
    public let promotionFalsePositiveRate: Double
    public let scamJunkRecall: Double
    public let rulesOverrideRate: Double

    public init(
        fixedAccuracy: Double,
        promotionAccuracy: Double,
        benignOrTransactionToJunk: Int,
        promotionFalsePositiveRate: Double,
        scamJunkRecall: Double,
        rulesOverrideRate: Double
    ) {
        self.fixedAccuracy = fixedAccuracy
        self.promotionAccuracy = promotionAccuracy
        self.benignOrTransactionToJunk = benignOrTransactionToJunk
        self.promotionFalsePositiveRate = promotionFalsePositiveRate
        self.scamJunkRecall = scamJunkRecall
        self.rulesOverrideRate = rulesOverrideRate
    }
}

public struct QuantizationDeviceMetrics: Codable, Hashable, Sendable {
    public let accelerationVerified: Bool
    public let peakPhysicalFootprintBytes: UInt64
    public let a12P95LatencyMilliseconds: Double
    public let a12P99LatencyMilliseconds: Double?
    public let extensionColdP95Milliseconds: Double?
    public let extensionColdP99Milliseconds: Double?
    public let extensionColdMaximumMilliseconds: Double?
    public let extensionWarmP95Milliseconds: Double?
    public let extensionWarmP99Milliseconds: Double?
    public let contentionFallbackP99Milliseconds: Double?
    public let jetsamCount: Int?
    public let memoryDriftBytes: UInt64?
    public let memoryDriftFraction: Double?
    public let coreMLTraceAcceleratorExecutionCount: Int?
    public let stressConditionsPassed: Bool?
    public let currentDevice: QuantizationRuntimeDeviceMetrics?

    public init(
        accelerationVerified: Bool,
        peakPhysicalFootprintBytes: UInt64,
        a12P95LatencyMilliseconds: Double,
        a12P99LatencyMilliseconds: Double? = nil,
        extensionColdP95Milliseconds: Double? = nil,
        extensionColdP99Milliseconds: Double? = nil,
        extensionColdMaximumMilliseconds: Double? = nil,
        extensionWarmP95Milliseconds: Double? = nil,
        extensionWarmP99Milliseconds: Double? = nil,
        contentionFallbackP99Milliseconds: Double? = nil,
        jetsamCount: Int? = nil,
        memoryDriftBytes: UInt64? = nil,
        memoryDriftFraction: Double? = nil,
        coreMLTraceAcceleratorExecutionCount: Int? = nil,
        stressConditionsPassed: Bool? = nil,
        currentDevice: QuantizationRuntimeDeviceMetrics? = nil
    ) {
        self.accelerationVerified = accelerationVerified
        self.peakPhysicalFootprintBytes = peakPhysicalFootprintBytes
        self.a12P95LatencyMilliseconds = a12P95LatencyMilliseconds
        self.a12P99LatencyMilliseconds = a12P99LatencyMilliseconds
        self.extensionColdP95Milliseconds = extensionColdP95Milliseconds
        self.extensionColdP99Milliseconds = extensionColdP99Milliseconds
        self.extensionColdMaximumMilliseconds = extensionColdMaximumMilliseconds
        self.extensionWarmP95Milliseconds = extensionWarmP95Milliseconds
        self.extensionWarmP99Milliseconds = extensionWarmP99Milliseconds
        self.contentionFallbackP99Milliseconds = contentionFallbackP99Milliseconds
        self.jetsamCount = jetsamCount
        self.memoryDriftBytes = memoryDriftBytes
        self.memoryDriftFraction = memoryDriftFraction
        self.coreMLTraceAcceleratorExecutionCount = coreMLTraceAcceleratorExecutionCount
        self.stressConditionsPassed = stressConditionsPassed
        self.currentDevice = currentDevice
    }
}

public struct QuantizationRuntimeDeviceMetrics: Codable, Hashable, Sendable {
    public let accelerationVerified: Bool
    public let peakPhysicalFootprintBytes: UInt64
    public let p50LatencyMilliseconds: Double
    public let p95LatencyMilliseconds: Double
    public let p99LatencyMilliseconds: Double
    public let extensionColdP95Milliseconds: Double
    public let extensionColdP99Milliseconds: Double
    public let extensionColdMaximumMilliseconds: Double
    public let extensionWarmP95Milliseconds: Double
    public let extensionWarmP99Milliseconds: Double
    public let contentionFallbackP99Milliseconds: Double
    public let jetsamCount: Int
    public let memoryDriftBytes: UInt64
    public let memoryDriftFraction: Double
    public let coldRunCount: Int
    public let warmQueryCount: Int
    public let coreMLTraceAcceleratorExecutionCount: Int
    public let stressConditionsPassed: Bool
    public let deviceModel: String?
    public let osVersion: String?

    public init(
        accelerationVerified: Bool,
        peakPhysicalFootprintBytes: UInt64,
        p50LatencyMilliseconds: Double,
        p95LatencyMilliseconds: Double,
        p99LatencyMilliseconds: Double,
        extensionColdP95Milliseconds: Double,
        extensionColdP99Milliseconds: Double,
        extensionColdMaximumMilliseconds: Double,
        extensionWarmP95Milliseconds: Double,
        extensionWarmP99Milliseconds: Double,
        contentionFallbackP99Milliseconds: Double,
        jetsamCount: Int,
        memoryDriftBytes: UInt64,
        memoryDriftFraction: Double,
        coldRunCount: Int,
        warmQueryCount: Int,
        coreMLTraceAcceleratorExecutionCount: Int,
        stressConditionsPassed: Bool,
        deviceModel: String? = nil,
        osVersion: String? = nil
    ) {
        self.accelerationVerified = accelerationVerified
        self.peakPhysicalFootprintBytes = peakPhysicalFootprintBytes
        self.p50LatencyMilliseconds = p50LatencyMilliseconds
        self.p95LatencyMilliseconds = p95LatencyMilliseconds
        self.p99LatencyMilliseconds = p99LatencyMilliseconds
        self.extensionColdP95Milliseconds = extensionColdP95Milliseconds
        self.extensionColdP99Milliseconds = extensionColdP99Milliseconds
        self.extensionColdMaximumMilliseconds = extensionColdMaximumMilliseconds
        self.extensionWarmP95Milliseconds = extensionWarmP95Milliseconds
        self.extensionWarmP99Milliseconds = extensionWarmP99Milliseconds
        self.contentionFallbackP99Milliseconds = contentionFallbackP99Milliseconds
        self.jetsamCount = jetsamCount
        self.memoryDriftBytes = memoryDriftBytes
        self.memoryDriftFraction = memoryDriftFraction
        self.coldRunCount = coldRunCount
        self.warmQueryCount = warmQueryCount
        self.coreMLTraceAcceleratorExecutionCount = coreMLTraceAcceleratorExecutionCount
        self.stressConditionsPassed = stressConditionsPassed
        self.deviceModel = deviceModel
        self.osVersion = osVersion
    }
}
