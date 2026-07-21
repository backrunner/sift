import Foundation
import MessageFilterCore
import MessageFilterExtensionKit
import XCTest

final class TransformerDeviceTests: XCTestCase {
    private static let candidateDirectoryName = ".DeviceBenchmarkCandidate"
    private static let evidenceDirectoryName = "DeviceEvidence"

    func testInstalledTransformerRuntimeBenchmark() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Accelerator and memory evidence must be collected on a physical iPhone")
        #else
        guard TransformerDeviceSupport.current().isSupported else {
            throw XCTSkip("This device is below the Premium Transformer hardware gate")
        }
        #endif

        let installed = try prepareInstalledModel()
        let compiledModelURL = installed.modelURL.pathExtension == "mlmodelc"
            ? installed.modelURL
            : TransformerModelStore.compiledModelURL(in: installed.directoryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compiledModelURL.path))

        let tokenizer = try BPETokenizer(
            tokenizerURL: installed.tokenizerURL,
            configuration: .init(maxSequenceLength: installed.manifest.maxSequenceLength)
        )
        let measuredIterations = Self.measuredIterations()
        let report = try await TransformerRuntimeBenchmark.run(
            modelURL: compiledModelURL,
            tokenizer: tokenizer,
            labels: installed.manifest.labels,
            requests: Self.benchmarkRequests,
            artifactIdentity: installed.manifest.artifactIdentity,
            warmupIterations: 20,
            measuredIterations: measuredIterations
        )

        XCTAssertEqual(report.artifactIdentity, installed.manifest.artifactIdentity)
        XCTAssertEqual(report.measuredIterations, measuredIterations)
        XCTAssertGreaterThan(report.computePlan.costedOperationCount, 0)
        XCTAssertTrue(report.computePlan.accelerationVerified)
        XCTAssertGreaterThan(report.postWarmupPhysicalFootprintBytes, 0)
        XCTAssertGreaterThan(report.peakPhysicalFootprintBytes, 0)
        XCTAssertTrue(report.p95LatencyMilliseconds.isFinite)
        XCTAssertLessThan(report.p95LatencyMilliseconds, 500)
        let allowedDrift = max(
            Int64(Double(report.postWarmupPhysicalFootprintBytes) * 0.10),
            16 * 1_024 * 1_024
        )
        XCTAssertLessThanOrEqual(abs(report.physicalFootprintDriftBytes), allowedDrift)

        let evidenceDirectory = try Self.evidenceDirectory()
        try Self.writeJSON(report, to: evidenceDirectory.appendingPathComponent("runtime-benchmark.json"))
        let filterSnapshot = MessageFilterPerformanceEvidenceStore().snapshot()
        try Self.writeJSON(
            filterSnapshot,
            to: evidenceDirectory.appendingPathComponent("message-filter-snapshot.json")
        )

        let attachment = XCTAttachment(
            data: try JSONEncoder.pretty.encode(report),
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "runtime-benchmark-\(report.deviceModel)-release-\(installed.manifest.releaseSequence)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func prepareInstalledModel() throws -> InstalledTransformerModel {
        let fileManager = FileManager.default
        let transferRoot = try Self.deviceTransferDirectory(fileManager: fileManager)

        if fileManager.fileExists(atPath: transferRoot.path) {
            let sourceDirectory = try Self.resolveCandidateDirectory(
                transferRoot: transferRoot,
                fileManager: fileManager
            )
            guard
                let candidate = TransformerModelStore.model(
                    in: sourceDirectory,
                    fileManager: fileManager,
                    validateChecksums: true
                ),
                candidate.manifest.runtimeProfile.computeUnits == "all",
                [4, 8].contains(candidate.manifest.quantizationProfile.weightBits)
            else {
                throw DeviceBenchmarkError.invalidCandidate
            }
            try TransformerClassifierLoader.prepareDownloadedModel(
                in: sourceDirectory,
                fileManager: fileManager
            )
            try TransformerModelStore.activate(
                stagedDirectory: sourceDirectory,
                fileManager: fileManager
            )
            FilterConfigurationSnapshotStore.refreshModelArtifactIdentity()
            if sourceDirectory.standardizedFileURL != transferRoot.standardizedFileURL,
               fileManager.fileExists(atPath: transferRoot.path) {
                try fileManager.removeItem(at: transferRoot)
            }
        }

        guard
            let installed = TransformerModelStore.installedModel(
                fileManager: fileManager,
                validateChecksums: true
            ),
            TransformerClassifierLoader.isReady(installed, fileManager: fileManager),
            installed.manifest.runtimeProfile.computeUnits == "all"
        else {
            throw DeviceBenchmarkError.missingInstalledModel
        }
        return installed
    }

    private static func resolveCandidateDirectory(
        transferRoot: URL,
        fileManager: FileManager
    ) throws -> URL {
        if TransformerModelStore.model(
            in: transferRoot,
            fileManager: fileManager,
            validateChecksums: false
        ) != nil {
            return transferRoot
        }
        let children = try fileManager.contentsOfDirectory(
            at: transferRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard let candidate = children.first(where: {
            TransformerModelStore.model(
                in: $0,
                fileManager: fileManager,
                validateChecksums: false
            ) != nil
        }) else {
            throw DeviceBenchmarkError.invalidCandidate
        }
        return candidate
    }

    private static func evidenceDirectory() throws -> URL {
        let directory = try deviceTransferRoot()
            .appendingPathComponent(evidenceDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func deviceTransferDirectory(fileManager: FileManager) throws -> URL {
        try deviceTransferRoot(fileManager: fileManager)
            .appendingPathComponent(candidateDirectoryName, isDirectory: true)
    }

    private static func deviceTransferRoot(fileManager: FileManager = .default) throws -> URL {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: ModelSelectionStore.appGroupIdentifier
        ) else {
            throw DeviceBenchmarkError.missingAppGroupContainer
        }
        return container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sift", isDirectory: true)
            .appendingPathComponent(TransformerModelStore.directoryName, isDirectory: true)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder.pretty.encode(value).write(to: url, options: .atomic)
    }

    private static func measuredIterations() -> Int {
        let raw = ProcessInfo.processInfo.environment["SIFT_DEVICE_BENCHMARK_ITERATIONS"]
        return min(max(Int(raw ?? "") ?? 1_000, 100), 10_000)
    }

    private static let benchmarkRequests: [MessageFilterRequest] = [
        MessageFilterRequest(sender: "GAME-MARKET", body: "您的游戏道具订单已支付，卖家正在准备交付。"),
        MessageFilterRequest(sender: "10086", body: "老用户升级5G套餐可获视频会员与20GB加赠流量。"),
        MessageFilterRequest(sender: "METRO-REWARDS", body: "You earned 860 points; your available balance is now 12,430."),
        MessageFilterRequest(sender: "FAST-CASH", body: "Pay an unlock fee first and message the agent to release the loan."),
        MessageFilterRequest(sender: "SYSTEM", body: "システム通知：フォロー中のサービスに更新があります。"),
        MessageFilterRequest(sender: "POINT-MALL", body: "銀行ポイントモールで家電交換キャンペーン開催中。"),
    ]
}

private enum DeviceBenchmarkError: Error {
    case invalidCandidate
    case missingInstalledModel
    case missingAppGroupContainer
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
