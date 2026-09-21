import Foundation
import MessageFilterCore
import MessageFilterExtensionKit
import SiftAppKit
import XCTest

/// Explicitly opted-in integration test. Normal unit tests never access the
/// model server. This runs the production app downloader and real Core ML,
/// but the engine runs in the host app, not an IdentityLookup process.
final class TransformerLiveDownloadTests: XCTestCase {
    @MainActor
    func testProductionDownloadLoadsAndExecutesSignal() async throws {
        guard ProcessInfo.processInfo.environment["SIFT_LIVE_MODEL_DOWNLOAD"] == "1" else {
            throw XCTSkip("Set SIFT_LIVE_MODEL_DOWNLOAD=1 to download the production model")
        }
        _ = try XCTUnwrap(
            ModelSelectionStore.sharedContainerURL(),
            "The live test host must be signed with the App Group entitlement"
        )
        let downloader = try XCTUnwrap(TransformerModelDownloadClient.configured())
        let suiteName = "SiftLiveDownload.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let sampleURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(suiteName).ndjson")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            if FileManager.default.fileExists(atPath: sampleURL.path) {
                try? FileManager.default.removeItem(at: sampleURL)
            }
        }
        #if targetEnvironment(simulator)
        // CPU-only simulator execution is useful integration evidence, not
        // physical-device support or extension memory evidence.
        let support = TransformerDeviceSupport.supported
        let environment = "iOS simulator host app; IdentityLookup not exercised"
        #else
        let support = TransformerDeviceSupport.current()
        let environment = "physical iPhone host app; IdentityLookup not exercised"
        #endif
        XCTAssertTrue(support.isSupported)
        let model = SiftAppModel(
            remoteSampleClient: LiveDownloadNoCloudClient(),
            premiumBackend: LiveDownloadEntitledBackend(),
            transformerAvailabilityOverride: false,
            transformerDownloadedOverride: false,
            transformerDeviceSupportOverride: support,
            transformerDownloader: downloader,
            modelSelectionDefaults: defaults,
            appDefaults: defaults,
            ledgerDefaults: defaults,
            categoryMappingDefaults: defaults,
            ruleDefaults: defaults,
            sampleStore: LocalSampleStore(fileURL: sampleURL)
        )
        defer { model.cancelPendingTransformerDownload() }
        try await waitUntil(timeout: .seconds(10)) {
            model.premium.isEntitlementResolved && !model.isSwitchingModelVariant
        }
        XCTAssertTrue(model.premium.isUnlocked)
        model.selectModelVariant(.transformer)
        var progressSamples: Set<Int64> = []
        var phases: Set<String> = []
        let started = ContinuousClock.now
        try await waitUntil(timeout: .seconds(240)) {
            let phase = String(describing: model.transformerDownloadPhase)
            if phases.insert(phase).inserted { print("LIVE_DOWNLOAD phase=\(phase)") }
            if let progress = model.transformerDownloadProgress {
                progressSamples.insert(progress.receivedBytes)
            }
            if case .failed(let message) = model.transformerDownloadPhase {
                throw LiveDownloadError.failed(message)
            }
            if model.transformerDownloadPhase == .waitingForTrafficConfirmation {
                throw LiveDownloadError.failed("Live verification requires an unmetered network")
            }
            return model.transformerDownloadPhase == .ready
                && model.selectedModelVariant == .transformer
                && !model.isSwitchingModelVariant
        }
        let elapsed = started.duration(to: .now) / .milliseconds(1)
        print("LIVE_DOWNLOAD app model loaded")
        let plan = try XCTUnwrap(model.pendingTransformerDownloadPlan)
        let total = try XCTUnwrap(plan.exactByteCount)
        let installed = try XCTUnwrap(TransformerModelStore.installedModel(validateChecksums: true))
        XCTAssertEqual(installed.manifest.artifactIdentity, plan.manifest.artifactIdentity)
        XCTAssertTrue(model.isTransformerModelAvailable)
        XCTAssertTrue(model.isTransformerModelDownloaded)
        XCTAssertEqual(model.transformerDownloadProgress?.receivedBytes, total)
        XCTAssertTrue(progressSamples.contains { $0 > 0 && $0 < total }, "Must observe real intermediate download progress")
        print("LIVE_DOWNLOAD verified \(total) bytes; \(progressSamples.count) progress samples")

        let configuration = FilterConfigurationSnapshotStore.load(defaults: defaults)
        XCTAssertEqual(configuration.selectedVariant, .transformer)
        XCTAssertEqual(configuration.modelArtifactIdentity, installed.manifest.artifactIdentity)
        let requests: [(String, String, SystemAction)] = [
            ("zh", "您的游戏道具订单已支付，卖家正在准备交付。", .transaction),
            ("en", "Pay an unlock fee first and message the agent to release the loan.", .junk),
            ("ja", "銀行ポイントモールで家電交換キャンペーン開催中。", .promotion),
        ]
        var results: [LiveDownloadEvidence.Query] = []
        // A new engine exercises cold loading independently of the app's
        // classifier. Subsequent requests exercise the retained runtime.
        let engine = MessageFilterEngine(transformerDeviceSupport: support)
        for (language, body, action) in requests {
            let result = await engine.classify(
                MessageFilterRequest(sender: nil, body: body), configuration: configuration
            )
            XCTAssertEqual(result.executionPath, .signal)
            XCTAssertEqual(result.fallbackReason, .none)
            XCTAssertEqual(result.decision.source, .model)
            XCTAssertEqual(result.systemAction, action)
            XCTAssertEqual(result.modelArtifactIdentity, installed.manifest.artifactIdentity)
            print("LIVE_DOWNLOAD \(language): \(result.executionPath.rawValue), \(result.systemAction.rawValue), fallback=\(result.fallbackReason.rawValue)")
            results.append(.init(language: language, action: result.systemAction.rawValue,
                                 executionPath: result.executionPath.rawValue,
                                 fallbackReason: result.fallbackReason.rawValue))
        }
        let evidence = LiveDownloadEvidence(
            environment: environment, artifactIdentity: installed.manifest.artifactIdentity,
            manifestURL: plan.manifestURL.absoluteString, downloadBytes: total,
            progressSamples: progressSamples.sorted(), phases: phases.sorted(),
            downloadAndLoadMilliseconds: elapsed, queries: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(evidence)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "production-download-and-engine-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try data.write(to: documents.appendingPathComponent("production-download-and-engine-evidence.json"), options: .atomic)
    }

    @MainActor
    private func waitUntil(timeout: Duration, _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LiveDownloadError.failed("Timed out waiting for live download or model loading")
    }
}

private enum LiveDownloadError: Error { case failed(String) }

private struct LiveDownloadEvidence: Encodable {
    struct Query: Encodable {
        let language: String
        let action: String
        let executionPath: String
        let fallbackReason: String
    }
    let environment: String
    let artifactIdentity: ModelArtifactIdentity
    let manifestURL: String
    let downloadBytes: Int64
    let progressSamples: [Int64]
    let phases: [String]
    let downloadAndLoadMilliseconds: Double
    let queries: [Query]
}

private struct LiveDownloadEntitledBackend: PremiumPurchasing {
    func loadProduct(identifier: String) async throws -> PremiumProductInfo? { nil }
    func purchase(identifier: String) async -> PremiumPurchaseOutcome { .cancelled }
    func entitlementStatus(identifier: String) async -> PremiumEntitlementStatus { .entitled }
    func restore(identifier: String) async throws -> PremiumEntitlementStatus { .entitled }
    func entitlementUpdates(identifier: String) -> AsyncStream<PremiumEntitlementStatus> {
        AsyncStream { $0.finish() }
    }
}

private struct LiveDownloadNoCloudClient: RemoteSampleSubmitting {
    func accountStatus() async -> RemoteSampleAccountStatus { .noAccount }
    func submit(sanitizedText: String, labelID: String, modelVersion: String?, assessment: LocalAssessment?) async throws -> RemoteSampleReceipt {
        throw RemoteSampleClientError.cloudKitUnavailable
    }
    func delete(receiptToken: String) async throws -> Bool { throw RemoteSampleClientError.cloudKitUnavailable }
    func fetchMySubmissions() async throws -> [RemoteSubmissionSummary] { [] }
    func fetchMySubmissions(before createdAtMillis: Int64?, limit: Int) async throws -> [RemoteSubmissionSummary] { [] }
    func eraseAllSubmissions() async throws -> Int { throw RemoteSampleClientError.cloudKitUnavailable }
}
