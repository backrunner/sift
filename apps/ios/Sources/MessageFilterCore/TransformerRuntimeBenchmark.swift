import Foundation

#if canImport(CoreML)
import CoreML

public struct TransformerComputePlanReport: Codable, Hashable, Sendable {
    public let operationCount: Int
    public let costedOperationCount: Int
    public let cpuPreferredCost: Double
    public let gpuPreferredCost: Double
    public let neuralEnginePreferredCost: Double
    public let highestCostOperationDevice: String?
    public let accelerationVerified: Bool
}

public enum TransformerComputePlanInspector {
    public static func inspect(
        modelURL: URL,
        computeUnits: String = "all"
    ) async throws -> TransformerComputePlanReport {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = try resolvedComputeUnits(computeUnits)
        let plan = try await MLComputePlan.load(contentsOf: modelURL, configuration: configuration)
        guard case let .program(program) = plan.modelStructure else {
            return TransformerComputePlanReport(
                operationCount: 0,
                costedOperationCount: 0,
                cpuPreferredCost: 0,
                gpuPreferredCost: 0,
                neuralEnginePreferredCost: 0,
                highestCostOperationDevice: nil,
                accelerationVerified: false
            )
        }

        let operations = program.functions.values.flatMap { flattenedOperations(in: $0.block) }
        var cpuCost = 0.0
        var gpuCost = 0.0
        var neuralEngineCost = 0.0
        var costedOperationCount = 0
        var highestCost = -Double.infinity
        var highestCostDevice: String?

        for operation in operations {
            guard
                let cost = plan.estimatedCost(of: operation)?.weight,
                let device = plan.deviceUsage(for: operation)?.preferred
            else {
                continue
            }
            costedOperationCount += 1
            let name = deviceName(device)
            switch name {
            case "neuralEngine": neuralEngineCost += cost
            case "gpu": gpuCost += cost
            default: cpuCost += cost
            }
            if cost > highestCost {
                highestCost = cost
                highestCostDevice = name
            }
        }
        return TransformerComputePlanReport(
            operationCount: operations.count,
            costedOperationCount: costedOperationCount,
            cpuPreferredCost: cpuCost,
            gpuPreferredCost: gpuCost,
            neuralEnginePreferredCost: neuralEngineCost,
            highestCostOperationDevice: highestCostDevice,
            accelerationVerified: (gpuCost > 0 || neuralEngineCost > 0) && highestCostDevice != "cpu"
        )
    }

    private static func flattenedOperations(
        in block: MLModelStructure.Program.Block
    ) -> [MLModelStructure.Program.Operation] {
        block.operations.flatMap { operation in
            [operation] + operation.blocks.flatMap(flattenedOperations(in:))
        }
    }

    private static func deviceName(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu: return "cpu"
        case .gpu: return "gpu"
        case .neuralEngine: return "neuralEngine"
        @unknown default: return "unknown"
        }
    }

    private static func resolvedComputeUnits(_ identifier: String) throws -> MLComputeUnits {
        switch identifier {
        case "all": return .all
        case "cpuOnly": return .cpuOnly
        case "cpuAndGPU": return .cpuAndGPU
        case "cpuAndNeuralEngine": return .cpuAndNeuralEngine
        default: throw CocoaError(.featureUnsupported)
        }
    }
}

public struct TransformerRuntimeBenchmarkReport: Codable, Hashable, Sendable {
    public let artifactIdentity: ModelArtifactIdentity?
    public let deviceModel: String
    public let osVersion: String
    public let computeUnits: String
    public let warmupIterations: Int
    public let measuredIterations: Int
    public let coldLoadMilliseconds: Double
    public let p50LatencyMilliseconds: Double
    public let p95LatencyMilliseconds: Double
    public let p99LatencyMilliseconds: Double
    public let baselinePhysicalFootprintBytes: UInt64
    public let postLoadPhysicalFootprintBytes: UInt64
    public let postWarmupPhysicalFootprintBytes: UInt64
    public let firstExecutionPeakPhysicalFootprintBytes: UInt64
    public let averagePhysicalFootprintBytes: UInt64
    public let steadyStatePeakPhysicalFootprintBytes: UInt64
    public let peakPhysicalFootprintBytes: UInt64
    public let finalPhysicalFootprintBytes: UInt64
    public let postLoadPhysicalFootprintIncreaseBytes: UInt64
    public let firstExecutionPeakPhysicalFootprintIncreaseBytes: UInt64
    public let averagePhysicalFootprintIncreaseBytes: UInt64
    public let steadyStatePeakPhysicalFootprintIncreaseBytes: UInt64
    public let peakPhysicalFootprintIncreaseBytes: UInt64
    public let finalPhysicalFootprintIncreaseBytes: UInt64
    public let physicalFootprintDriftBytes: Int64
    public let postComputePlanPhysicalFootprintBytes: UInt64
    public let computePlan: TransformerComputePlanReport
}

public enum TransformerRuntimeBenchmark {
    public static func run(
        modelURL: URL,
        tokenizer: any TextTokenizing,
        labels: [String],
        requests: [MessageFilterRequest],
        artifactIdentity: ModelArtifactIdentity? = nil,
        computeUnits: String = "all",
        baselinePhysicalFootprintBytes: UInt64? = nil,
        warmupIterations: Int = 10,
        measuredIterations: Int = 100
    ) async throws -> TransformerRuntimeBenchmarkReport {
        precondition(!requests.isEmpty)
        precondition(warmupIterations >= 0 && measuredIterations > 0)

        let clock = ContinuousClock()
        let baselineFootprint = baselinePhysicalFootprintBytes ?? currentPhysicalFootprintBytes()
        let loadStart = clock.now
        let classifier = try TransformerTextClassifier(
            modelURL: modelURL,
            tokenizer: tokenizer,
            labels: labels,
            computeUnits: computeUnits
        )
        let coldLoadMilliseconds = milliseconds(loadStart.duration(to: clock.now))
        let postLoadFootprint = currentPhysicalFootprintBytes()
        var firstExecutionPeakFootprint = postLoadFootprint

        for index in 0..<warmupIterations {
            let request = requests[index % requests.count]
            autoreleasepool {
                _ = classifier.classify(sender: request.sender, body: request.body)
            }
            firstExecutionPeakFootprint = max(
                firstExecutionPeakFootprint,
                currentPhysicalFootprintBytes()
            )
        }

        let postWarmupFootprint = currentPhysicalFootprintBytes()
        firstExecutionPeakFootprint = max(firstExecutionPeakFootprint, postWarmupFootprint)
        var durations: [Double] = []
        durations.reserveCapacity(measuredIterations)
        var steadyStatePeakFootprint = postWarmupFootprint
        var footprintSampleTotal: UInt64 = 0
        for index in 0..<measuredIterations {
            let request = requests[index % requests.count]
            let start = clock.now
            autoreleasepool {
                _ = classifier.classify(sender: request.sender, body: request.body)
            }
            durations.append(milliseconds(start.duration(to: clock.now)))
            let footprint = currentPhysicalFootprintBytes()
            footprintSampleTotal += footprint
            steadyStatePeakFootprint = max(steadyStatePeakFootprint, footprint)
        }
        durations.sort()
        let finalInferenceFootprint = currentPhysicalFootprintBytes()
        steadyStatePeakFootprint = max(steadyStatePeakFootprint, finalInferenceFootprint)
        let peakFootprint = max(firstExecutionPeakFootprint, steadyStatePeakFootprint)
        let averageFootprint = footprintSampleTotal / UInt64(measuredIterations)

        // MLComputePlan inspection is release evidence, not part of the extension's
        // inference path. Keep its allocations out of inference peak and drift.
        let computePlan = try await TransformerComputePlanInspector.inspect(
            modelURL: modelURL,
            computeUnits: computeUnits
        )
        let postComputePlanFootprint = currentPhysicalFootprintBytes()

        return TransformerRuntimeBenchmarkReport(
            artifactIdentity: artifactIdentity,
            deviceModel: hardwareIdentifier(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            computeUnits: computeUnits,
            warmupIterations: warmupIterations,
            measuredIterations: measuredIterations,
            coldLoadMilliseconds: coldLoadMilliseconds,
            p50LatencyMilliseconds: percentile(0.50, values: durations),
            p95LatencyMilliseconds: percentile(0.95, values: durations),
            p99LatencyMilliseconds: percentile(0.99, values: durations),
            baselinePhysicalFootprintBytes: baselineFootprint,
            postLoadPhysicalFootprintBytes: postLoadFootprint,
            postWarmupPhysicalFootprintBytes: postWarmupFootprint,
            firstExecutionPeakPhysicalFootprintBytes: firstExecutionPeakFootprint,
            averagePhysicalFootprintBytes: averageFootprint,
            steadyStatePeakPhysicalFootprintBytes: steadyStatePeakFootprint,
            peakPhysicalFootprintBytes: peakFootprint,
            finalPhysicalFootprintBytes: finalInferenceFootprint,
            postLoadPhysicalFootprintIncreaseBytes: positiveDifference(postLoadFootprint, baselineFootprint),
            firstExecutionPeakPhysicalFootprintIncreaseBytes: positiveDifference(
                firstExecutionPeakFootprint,
                baselineFootprint
            ),
            averagePhysicalFootprintIncreaseBytes: positiveDifference(averageFootprint, baselineFootprint),
            steadyStatePeakPhysicalFootprintIncreaseBytes: positiveDifference(
                steadyStatePeakFootprint,
                baselineFootprint
            ),
            peakPhysicalFootprintIncreaseBytes: positiveDifference(peakFootprint, baselineFootprint),
            finalPhysicalFootprintIncreaseBytes: positiveDifference(finalInferenceFootprint, baselineFootprint),
            physicalFootprintDriftBytes: signedDifference(finalInferenceFootprint, postWarmupFootprint),
            postComputePlanPhysicalFootprintBytes: postComputePlanFootprint,
            computePlan: computePlan
        )
    }

    private static func percentile(_ percentile: Double, values: [Double]) -> Double {
        let index = min(Int((Double(values.count - 1) * percentile).rounded(.up)), values.count - 1)
        return values[index]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

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

    private static func signedDifference(_ lhs: UInt64, _ rhs: UInt64) -> Int64 {
        if lhs >= rhs {
            return Int64(min(lhs - rhs, UInt64(Int64.max)))
        }
        return -Int64(min(rhs - lhs, UInt64(Int64.max)))
    }

    private static func positiveDifference(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > rhs ? lhs - rhs : 0
    }

    private static func hardwareIdentifier() -> String {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var machine = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else {
            return "unknown"
        }
        let bytes = machine.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
        #else
        return "unknown"
        #endif
    }
}
#endif
