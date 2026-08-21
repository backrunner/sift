#if canImport(Testing)
import Foundation
import MessageFilterCore
@testable import SiftAppKit
import Testing

// MARK: - Premium gating

private actor PremiumEntitlementRecorder {
    private var count = 0

    func record() {
        count += 1
    }

    func callCount() -> Int {
        count
    }
}

private struct MockPremiumBackend: PremiumPurchasing {
    let entitled: Bool
    let outcome: PremiumPurchaseOutcome
    var product: PremiumProductInfo? = PremiumProductInfo(
        identifier: "com.alkinum.sift.premium",
        displayName: "高级版",
        displayPrice: "¥18.00",
        price: 18
    )
    var loadError: (any Error & Sendable)?
    var entitlementRecorder: PremiumEntitlementRecorder?
    var entitlementStatusOverride: PremiumEntitlementStatus?

    func loadProduct(identifier: String) async throws -> PremiumProductInfo? {
        if let loadError {
            throw loadError
        }
        return product
    }

    func purchase(identifier: String) async -> PremiumPurchaseOutcome {
        outcome
    }

    func entitlementStatus(identifier: String) async -> PremiumEntitlementStatus {
        if let entitlementRecorder {
            await entitlementRecorder.record()
        }
        return entitlementStatusOverride ?? (entitled ? .entitled : .notPurchased)
    }

    func restore(identifier: String) async throws -> PremiumEntitlementStatus {
        entitlementStatusOverride ?? (entitled ? .entitled : .notPurchased)
    }

    func entitlementUpdates(identifier: String) -> AsyncStream<PremiumEntitlementStatus> {
        AsyncStream { $0.finish() }
    }
}

private actor SuspendedPremiumEntitlementGate {
    private var requestCount = 0
    private var continuation: CheckedContinuation<PremiumEntitlementStatus, Never>?

    func entitlementStatus() async -> PremiumEntitlementStatus {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ status: PremiumEntitlementStatus) {
        continuation?.resume(returning: status)
        continuation = nil
    }

    func count() -> Int {
        requestCount
    }
}

private struct SuspendedPremiumBackend: PremiumPurchasing {
    let gate: SuspendedPremiumEntitlementGate

    func loadProduct(identifier: String) async throws -> PremiumProductInfo? {
        PremiumProductInfo(
            identifier: identifier,
            displayName: "高级版",
            displayPrice: "¥18.00",
            price: 18
        )
    }

    func purchase(identifier: String) async -> PremiumPurchaseOutcome { .cancelled }

    func entitlementStatus(identifier: String) async -> PremiumEntitlementStatus {
        await gate.entitlementStatus()
    }

    func restore(identifier: String) async throws -> PremiumEntitlementStatus { .notPurchased }

    func entitlementUpdates(identifier: String) -> AsyncStream<PremiumEntitlementStatus> {
        AsyncStream { $0.finish() }
    }
}

private actor TransformerDownloadRecorder {
    private(set) var prepareCallCount = 0
    private(set) var downloadCallCount = 0
    private(set) var downloadModes: [TransformerModelDownloadMode] = []

    func recordPrepare() {
        prepareCallCount += 1
    }

    func recordDownload(mode: TransformerModelDownloadMode) {
        downloadCallCount += 1
        downloadModes.append(mode)
    }

    func counts() -> (prepare: Int, download: Int) {
        (prepareCallCount, downloadCallCount)
    }

    func modes() -> [TransformerModelDownloadMode] {
        downloadModes
    }
}

private struct MockTransformerDownloader: TransformerModelDownloading {
    let plan: TransformerModelDownloadPlan
    let recorder: TransformerDownloadRecorder

    init(
        plan: TransformerModelDownloadPlan,
        recorder: TransformerDownloadRecorder = TransformerDownloadRecorder()
    ) {
        self.plan = plan
        self.recorder = recorder
    }

    func prepareDownload() async throws -> TransformerModelDownloadPlan {
        await recorder.recordPrepare()
        return plan
    }

    func download(
        _ plan: TransformerModelDownloadPlan,
        progress: @Sendable @escaping (TransformerModelDownloadProgress) -> Void,
        phase: @Sendable @escaping (TransformerModelDownloadWorkPhase) -> Void
    ) async throws {
        await recorder.recordDownload(mode: plan.mode)
        phase(.downloading)
        progress(TransformerModelDownloadProgress(receivedBytes: plan.displayByteCount ?? 1, totalBytes: plan.displayByteCount))
        phase(.installing)
    }
}

@Test
func transformerChannelRequestsForceConditionalRevalidation() throws {
    let url = try #require(URL(string: "https://example.com/models/channel.json"))
    let request = TransformerModelDownloadClient.channelRequest(
        url: url,
        etag: "\"catalog-v3\"",
        cacheBuster: "request-4"
    )

    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.url?.absoluteString == "https://example.com/models/channel.json?_sift_revalidate=request-4")
    #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache, max-age=0")
    #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"catalog-v3\"")
}

private actor SuspendedTransformerDownloadGate {
    private var callCount = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func suspend() async {
        callCount += 1
        let call = callCount
        await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func release(_ call: Int) {
        continuations.removeValue(forKey: call)?.resume()
    }

    func count() -> Int {
        callCount
    }
}

private struct SuspendedTransformerDownloader: TransformerModelDownloading {
    let plan: TransformerModelDownloadPlan
    let gate: SuspendedTransformerDownloadGate

    func prepareDownload() async throws -> TransformerModelDownloadPlan {
        plan
    }

    func download(
        _ plan: TransformerModelDownloadPlan,
        progress: @Sendable @escaping (TransformerModelDownloadProgress) -> Void,
        phase: @Sendable @escaping (TransformerModelDownloadWorkPhase) -> Void
    ) async throws {
        await gate.suspend()
    }
}

private struct MockTransformerUpdateChecker: TransformerModelUpdateChecking {
    let state: TransformerUpdateState

    func checkForUpdate(currentIdentity: ModelArtifactIdentity?) async -> TransformerUpdateState {
        state
    }
}

private actor NetworkConditionRecorder {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }
}

private struct MockNetworkConditionChecker: TransformerNetworkConditionChecking {
    let condition: TransformerNetworkCondition
    let recorder: NetworkConditionRecorder

    func currentCondition() async -> TransformerNetworkCondition {
        await recorder.record()
        return condition
    }
}

private struct MockSiftModelClassifierLoader: SiftModelClassifierLoading {
    @concurrent
    func classifier(for variant: ModelVariant) async -> (any MessageClassifier)? {
        HeuristicClassifier()
    }
}

private struct SlowTransformerClassifierLoader: SiftModelClassifierLoading {
    let delay: Duration

    @concurrent
    func classifier(for variant: ModelVariant) async -> (any MessageClassifier)? {
        if variant == .transformer {
            try? await Task.sleep(for: delay)
        }
        return HeuristicClassifier()
    }
}

private actor ModelLoadRecorder {
    private var variants: [ModelVariant] = []

    func record(_ variant: ModelVariant) {
        variants.append(variant)
    }

    func recordedVariants() -> [ModelVariant] {
        variants
    }
}

private struct RecordingModelClassifierLoader: SiftModelClassifierLoading {
    let recorder: ModelLoadRecorder

    @concurrent
    func classifier(for variant: ModelVariant) async -> (any MessageClassifier)? {
        await recorder.record(variant)
        return HeuristicClassifier()
    }
}

private actor MessageFilterRuntimeRecorder {
    private var identities: [ModelArtifactIdentity] = []

    func record(_ identity: ModelArtifactIdentity) {
        identities.append(identity)
    }

    func recordedIdentities() -> [ModelArtifactIdentity] {
        identities
    }
}

private struct RecordingMessageFilterRuntimeLoader: TransformerRuntimeLoading {
    let recorder: MessageFilterRuntimeRecorder

    @concurrent
    func loadTransformer(identity: ModelArtifactIdentity) async -> TransformerRuntimeLoadResult {
        await recorder.record(identity)
        return TransformerRuntimeLoadResult(classifier: HeuristicClassifier())
    }
}

private actor TransformerRemovalRecorder {
    private(set) var callCount = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func recordRemoval() async {
        callCount += 1
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func releaseRemoval() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private enum MockTransformerRemovalError: Error, Sendable {
    case failed
}

private struct MockTransformerModelRemover: TransformerModelRemoving {
    let recorder: TransformerRemovalRecorder
    var error: MockTransformerRemovalError? = nil

    @concurrent
    func removeInstalledModel() async throws {
        await recorder.recordRemoval()
        if let error {
            throw error
        }
    }
}

private func mockTransformerDownloadPlan(
    networkCondition: TransformerNetworkCondition = TransformerNetworkCondition()
) -> TransformerModelDownloadPlan {
    let manifest = TransformerModelManifest(
        schemaVersion: 2,
        releaseSequence: 1,
        modelABI: "sift-signal-v1",
        minimumAppBuild: 1,
        maximumAppBuild: 100,
        minimumOSVersion: "18.0",
        runtimeProfile: TransformerRuntimeProfile(),
        quantizationProfile: TransformerQuantizationProfile(
            identifier: "w8a16-channel-ptq",
            weightBits: 8,
            activationBits: 16,
            method: "ptq",
            granularity: "per-channel"
        ),
        validationMetrics: TransformerValidationMetrics(
            fixedAccuracy: 0.9958,
            promotionAccuracy: 0.98,
            fp16Agreement: 0.99,
            languageAccuracy: ["zh": 0.99, "en": 0.99, "ja": 0.99]
        ),
        version: "remote-0.1",
        trainedAt: "2026-07-07T08:00:00.000Z",
        algorithm: "supervised-sequence-classification",
        backbone: "jhu-clsp/mmBERT-small",
        languages: ["zh", "en", "ja"],
        labels: ["spam", "promotion"],
        maxSequenceLength: 8,
        doLowerCase: false,
        tokenizerKind: "bpe",
        tokenizerArtifact: "SiftSignalModel.tokenizer.siftbpe",
        modelArtifact: "SiftSignalModel.mlpackage",
        sha256: String(repeating: "b", count: 64),
        taxonomyHash: "taxonomy-sha256",
        tokenizerSHA256: String(repeating: "d", count: 64),
        remoteArtifacts: [
            TransformerRemoteArtifact(
                path: "SiftSignalModel.tokenizer.siftbpe",
                sha256: String(repeating: "d", count: 64),
                byteCount: 1024
            ),
            TransformerRemoteArtifact(
                path: "SiftSignalModel.mlpackage/model.mlmodel",
                sha256: String(repeating: "e", count: 64),
                byteCount: 2048
            )
        ],
        downloadBytes: 176_160_768
    )
    return TransformerModelDownloadPlan(
        manifest: manifest,
        manifestURL: URL(string: "https://example.com/SiftSignalModel.manifest.json")!,
        artifacts: [
            TransformerModelDownloadArtifact(
                remoteURL: URL(string: "https://example.com/SiftSignalModel.tokenizer.siftbpe")!,
                relativePath: "SiftSignalModel.tokenizer.siftbpe",
                sha256: String(repeating: "d", count: 64),
                byteCount: 1024
            ),
            TransformerModelDownloadArtifact(
                remoteURL: URL(string: "https://example.com/SiftSignalModel.mlpackage/model.mlmodel")!,
                relativePath: "SiftSignalModel.mlpackage/model.mlmodel",
                sha256: String(repeating: "e", count: 64),
                byteCount: 2048
            )
        ],
        exactByteCount: 176_160_768,
        estimatedByteCount: nil,
        networkCondition: networkCondition
    )
}

private func sift14DistilledManifest(
    algorithm: String = "teacher-student-distillation",
    provenance: TransformerDistillationProvenance? = TransformerDistillationProvenance(
        teacherCheckpointSHA256: String(repeating: "a", count: 64),
        teacherLayers: 22,
        studentLayers: 12,
        temperature: 2,
        distillAlpha: 0.7
    )
) -> TransformerModelManifest {
    let current = mockTransformerDownloadPlan().manifest
    return TransformerModelManifest(
        schemaVersion: 2,
        releaseSequence: 4,
        modelABI: current.modelABI,
        minimumAppBuild: 19,
        maximumAppBuild: current.maximumAppBuild,
        minimumOSVersion: current.minimumOSVersion,
        runtimeProfile: TransformerRuntimeProfile(
            computeUnits: "cpuOnly",
            computePrecision: "float32"
        ),
        quantizationProfile: TransformerQuantizationProfile(
            identifier: "w4a32-block16-ptq",
            weightBits: 4,
            activationBits: 32,
            method: "ptq",
            granularity: "per-block",
            blockSize: 16
        ),
        validationMetrics: current.validationMetrics,
        version: "signal-v4-generalization-v50-r32-distilled-12l",
        trainedAt: current.trainedAt,
        algorithm: algorithm,
        backbone: current.backbone,
        languages: current.languages,
        labels: current.labels,
        maxSequenceLength: current.maxSequenceLength,
        doLowerCase: current.doLowerCase,
        tokenizerKind: current.tokenizerKind,
        tokenizerArtifact: current.tokenizerArtifact,
        modelArtifact: current.modelArtifact,
        sha256: current.sha256,
        taxonomyHash: current.taxonomyHash,
        tokenizerSHA256: current.tokenizerSHA256,
        keyID: current.keyID,
        signature: current.signature,
        remoteArtifacts: current.remoteArtifacts,
        downloadBytes: current.downloadBytes,
        distillation: provenance
    )
}

@MainActor
@Test
func lockedTransformerSelectionOpensPaywallInsteadOfSwitching() async throws {
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: false, outcome: .cancelled),
        transformerAvailabilityOverride: true
    )
    try await waitForPremiumRefresh(model)

    #expect(!model.premium.isUnlocked)
    model.selectModelVariant(.transformer)

    #expect(model.isShowingPaywall)
    #expect(model.selectedModelVariant == .classic)
}

@MainActor
@Test
func unsupportedDeviceBlocksTransformerBeforePurchaseOrDownload() async throws {
    let recorder = TransformerDownloadRecorder()
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: false, outcome: .cancelled),
        transformerAvailabilityOverride: false,
        transformerDeviceSupportOverride: TransformerDeviceSupport(
            status: .unsupported,
            reason: .belowMinimumNeuralEngine
        ),
        transformerDownloader: MockTransformerDownloader(
            plan: mockTransformerDownloadPlan(),
            recorder: recorder
        )
    )
    try await waitForPremiumRefresh(model)

    #expect(!model.isTransformerDeviceSupported)
    #expect(!model.isModelVariantAvailable(.transformer))
    model.selectModelVariant(.transformer)

    #expect(!model.isShowingPaywall)
    #expect(model.selectedModelVariant == .classic)
    #expect(model.toastCenter.toast?.message == String(localized: "此设备不支持 Sift Signal 高级模型"))
    let counts = await recorder.counts()
    #expect(counts.prepare == 0)
    #expect(counts.download == 0)
}

@MainActor
@Test
func unlockedTransformerDoesNotDownloadUntilUserSelectsIt() async throws {
    let recorder = TransformerDownloadRecorder()
    let downloader = MockTransformerDownloader(
        plan: mockTransformerDownloadPlan(),
        recorder: recorder
    )
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: false,
        transformerDownloader: downloader
    )
    try await waitForPremiumRefresh(model)

    #expect(model.premium.isUnlocked)
    #expect(model.transformerDownloadPhase == .notDownloaded)
    #expect(model.selectedModelVariant == .classic)
    let counts = await recorder.counts()
    #expect(counts.prepare == 0)
    #expect(counts.download == 0)
}

@MainActor
@Test
func purchasedEntitlementRestoresSynchronouslyAndSkipsRecentValidation() async throws {
    let suiteName = "SiftTests.premium.cache.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let purchasedStore = PremiumStore(
        backend: MockPremiumBackend(entitled: false, outcome: .purchased),
        defaults: defaults
    )
    let feedback = await purchasedStore.purchase()
    #expect(feedback?.kind == .success)
    #expect(purchasedStore.isUnlocked)

    let recorder = PremiumEntitlementRecorder()
    let relaunchedStore = PremiumStore(
        backend: MockPremiumBackend(
            entitled: false,
            outcome: .cancelled,
            entitlementRecorder: recorder
        ),
        defaults: defaults
    )

    #expect(relaunchedStore.isUnlocked)
    #expect(relaunchedStore.isEntitlementResolved)
    relaunchedStore.refreshEntitlementIfNeeded()
    await Task.yield()
    #expect(await recorder.callCount() == 0)
}

@MainActor
@Test
func explicitNotPurchasedClearsCachedPremiumUnlock() async throws {
    let suiteName = "SiftTests.premium.validation.notPurchased.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: PremiumStore.cachedEntitlementKey)
    defaults.set(
        Date().addingTimeInterval(-PremiumStore.entitlementValidationInterval - 1),
        forKey: PremiumStore.entitlementLastValidatedAtKey
    )

    let recorder = PremiumEntitlementRecorder()
    let store = PremiumStore(
        backend: MockPremiumBackend(
            entitled: false,
            outcome: .cancelled,
            entitlementRecorder: recorder
        ),
        defaults: defaults
    )

    #expect(store.isUnlocked)
    try await waitForPremiumEntitlementCheck(recorder, count: 1)
    try await waitFor { store.isValidatingEntitlement == false }
    #expect(store.isUnlocked == false)
    #expect(defaults.bool(forKey: PremiumStore.cachedEntitlementKey) == false)
}

@MainActor
@Test
func unverifiedValidationPreservesCachedPremiumUnlock() async throws {
    let suiteName = "SiftTests.premium.validation.unverified.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: PremiumStore.cachedEntitlementKey)
    defaults.set(
        Date().addingTimeInterval(-PremiumStore.entitlementValidationInterval - 1),
        forKey: PremiumStore.entitlementLastValidatedAtKey
    )

    let store = PremiumStore(
        backend: MockPremiumBackend(
            entitled: false,
            outcome: .cancelled,
            entitlementStatusOverride: .unverified
        ),
        defaults: defaults
    )

    #expect(store.isUnlocked)
    try await waitFor { store.isValidatingEntitlement == false }
    #expect(store.isUnlocked)
    #expect(defaults.bool(forKey: PremiumStore.cachedEntitlementKey))
}

@MainActor
@Test
func unverifiedRestoreDoesNotRevokeCachedPremiumUnlock() async throws {
    let suiteName = "SiftTests.premium.restore.unverified.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: PremiumStore.cachedEntitlementKey)
    defaults.set(Date(), forKey: PremiumStore.entitlementLastValidatedAtKey)

    let store = PremiumStore(
        backend: MockPremiumBackend(
            entitled: false,
            outcome: .cancelled,
            entitlementStatusOverride: .unverified
        ),
        defaults: defaults
    )

    let feedback = await store.restorePurchases()

    #expect(feedback.kind == .error)
    #expect(store.isUnlocked)
    #expect(defaults.bool(forKey: PremiumStore.cachedEntitlementKey))
}

@MainActor
@Test
func explicitRevocationClearsCachedPremiumUnlock() async throws {
    let suiteName = "SiftTests.premium.validation.revoked.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: PremiumStore.cachedEntitlementKey)
    defaults.set(
        Date().addingTimeInterval(-PremiumStore.entitlementValidationInterval - 1),
        forKey: PremiumStore.entitlementLastValidatedAtKey
    )

    let store = PremiumStore(
        backend: MockPremiumBackend(
            entitled: false,
            outcome: .cancelled,
            entitlementStatusOverride: .revoked
        ),
        defaults: defaults
    )

    #expect(store.isUnlocked)
    try await waitFor { store.isValidatingEntitlement == false }
    #expect(store.isUnlocked == false)
    #expect(defaults.bool(forKey: PremiumStore.cachedEntitlementKey) == false)
}

@MainActor
@Test
func cachedNegativeWaitsForFreshRevocationBeforeStoredTransformerFallsBack() async throws {
    let suiteName = "SiftTests.modelSelection.entitlement.revoked.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    ModelSelectionStore.save(.transformer, defaults: defaults)
    defaults.set(false, forKey: PremiumStore.cachedEntitlementKey)
    defaults.set(Date(), forKey: PremiumStore.entitlementLastValidatedAtKey)

    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(
            entitled: false,
            outcome: .cancelled,
            entitlementStatusOverride: .revoked
        ),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: nil,
        modelClassifierLoader: MockSiftModelClassifierLoader(),
        modelSelectionDefaults: defaults,
        appDefaults: defaults
    )

    #expect(model.selectedModelVariant == .transformer)
    #expect(model.submissionDestination == .remote)
    #expect(ModelSelectionStore.load(defaults: defaults) == .transformer)
    #expect(model.premium.isValidatingEntitlement)
    try await waitFor { model.premium.isValidatingEntitlement == false }
    #expect(model.premium.isEntitlementResolved)
    #expect(model.premium.isUnlocked == false)
    try await waitFor { model.isSwitchingModelVariant == false }
    #expect(model.selectedModelVariant == .classic)
    #expect(ModelSelectionStore.load(defaults: defaults) == .classic)
}

@MainActor
@Test
func transformerUpdateCheckIsMetadataOnlyAndSurfacesCompatibleRelease() async throws {
    let suiteName = "SiftTests.modelUpdate.metadata.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let channel = TransformerChannelManifestV2(
        releaseSequence: 2,
        releaseID: "signal-v1",
        releaseManifestURL: "https://example.com/release.json",
        releaseManifestSHA256: "release-sha",
        modelABI: "sift-signal-v1",
        minimumAppBuild: 1,
        maximumAppBuild: 100,
        minimumOSVersion: "18.0",
        downloadBytes: 100_000_000,
        keyID: "test"
    )
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: nil,
        transformerUpdateChecker: MockTransformerUpdateChecker(state: .updateAvailable(channel)),
        modelSelectionDefaults: defaults,
        appDefaults: defaults
    )
    try await waitForPremiumRefresh(model)

    model.checkForTransformerUpdate(force: true)
    try await waitFor {
        if case .updateAvailable = model.transformerUpdateState { return true }
        return false
    }

    #expect(model.hasCompatibleTransformerUpdate)
    #expect(model.transformerUpdateReleaseID == "signal-v1")
    #expect(model.transformerUpdateDownloadSizeText != nil)
}

@MainActor
@Test
func automaticTransformerUpdateDoesNotDownloadWithoutWiFi() async throws {
    let suiteName = "SiftTests.modelUpdate.noWiFi.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    ModelSelectionStore.save(.transformer, defaults: defaults)

    let downloadRecorder = TransformerDownloadRecorder()
    let networkRecorder = NetworkConditionRecorder()
    let channel = TransformerChannelManifestV2(
        releaseSequence: 2,
        releaseID: "signal-v2",
        releaseManifestURL: "https://example.com/release.json",
        releaseManifestSHA256: String(repeating: "a", count: 64),
        modelABI: "sift-signal-v1",
        minimumAppBuild: 1,
        maximumAppBuild: 100,
        minimumOSVersion: "18.0",
        downloadBytes: 100_000_000,
        keyID: "test"
    )
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: MockTransformerDownloader(
            plan: mockTransformerDownloadPlan(),
            recorder: downloadRecorder
        ),
        transformerUpdateChecker: MockTransformerUpdateChecker(state: .updateAvailable(channel)),
        transformerNetworkConditionChecker: MockNetworkConditionChecker(
            condition: TransformerNetworkCondition(
                isConnected: true,
                usesWiFi: false,
                isExpensive: true
            ),
            recorder: networkRecorder
        ),
        modelClassifierLoader: MockSiftModelClassifierLoader(),
        modelSelectionDefaults: defaults,
        appDefaults: defaults
    )

    try await waitForPremiumRefresh(model)
    model.applicationDidBecomeActive()
    try await waitForNetworkConditionCheck(networkRecorder, count: 1)

    let counts = await downloadRecorder.counts()
    #expect(counts.prepare == 0)
    #expect(counts.download == 0)
    #expect(model.selectedModelVariant == .transformer)
    #expect(model.transformerDownloadPhase == .ready)
}

@MainActor
@Test
func automaticTransformerUpdateUsesSilentBackgroundDownloadOnWiFi() async throws {
    let suiteName = "SiftTests.modelUpdate.wifi.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    ModelSelectionStore.save(.transformer, defaults: defaults)

    let downloadRecorder = TransformerDownloadRecorder()
    let networkRecorder = NetworkConditionRecorder()
    let channel = TransformerChannelManifestV2(
        releaseSequence: 2,
        releaseID: "signal-v2",
        releaseManifestURL: "https://example.com/release.json",
        releaseManifestSHA256: String(repeating: "a", count: 64),
        modelABI: "sift-signal-v1",
        minimumAppBuild: 1,
        maximumAppBuild: 100,
        minimumOSVersion: "18.0",
        downloadBytes: 100_000_000,
        keyID: "test"
    )
    let plan = mockTransformerDownloadPlan(
        networkCondition: TransformerNetworkCondition(isConnected: true, usesWiFi: true)
    )
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: MockTransformerDownloader(plan: plan, recorder: downloadRecorder),
        transformerUpdateChecker: MockTransformerUpdateChecker(state: .updateAvailable(channel)),
        transformerNetworkConditionChecker: MockNetworkConditionChecker(
            condition: TransformerNetworkCondition(isConnected: true, usesWiFi: true),
            recorder: networkRecorder
        ),
        modelClassifierLoader: MockSiftModelClassifierLoader(),
        modelSelectionDefaults: defaults,
        appDefaults: defaults
    )

    try await waitForPremiumRefresh(model)
    model.applicationDidBecomeActive()
    try await waitForTransformerDownloadCall(downloadRecorder, count: 1)

    #expect(await downloadRecorder.modes() == [.automatic])
    #expect(model.selectedModelVariant == .transformer)
    #expect(model.isShowingMeteredTransformerDownloadConfirmation == false)
    #expect(model.transformerDownloadProgress == nil)
}

@MainActor
@Test
func pendingBackgroundDownloadReconnectBypassesRecentUpdateCheck() async throws {
    let suiteName = "SiftTests.modelUpdate.backgroundReconnect.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Date(), forKey: "Sift.transformerUpdateLastCheck.v1")

    let downloadRecorder = TransformerDownloadRecorder()
    let plan = mockTransformerDownloadPlan(
        networkCondition: TransformerNetworkCondition(isConnected: true, usesWiFi: true)
    )
    let channel = TransformerChannelManifestV2(
        releaseSequence: 2,
        releaseID: "signal-v2",
        releaseManifestURL: "https://example.com/release.json",
        releaseManifestSHA256: String(repeating: "a", count: 64),
        modelABI: "sift-signal-v1",
        minimumAppBuild: 1,
        maximumAppBuild: 100,
        minimumOSVersion: "18.0",
        downloadBytes: 100_000_000,
        keyID: "test"
    )
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: MockTransformerDownloader(plan: plan, recorder: downloadRecorder),
        transformerUpdateChecker: MockTransformerUpdateChecker(state: .updateAvailable(channel)),
        transformerNetworkConditionChecker: MockNetworkConditionChecker(
            condition: TransformerNetworkCondition(isConnected: true, usesWiFi: true),
            recorder: NetworkConditionRecorder()
        ),
        modelClassifierLoader: MockSiftModelClassifierLoader(),
        modelSelectionDefaults: defaults,
        appDefaults: defaults
    )

    try await waitForPremiumRefresh(model)
    model.resumeTransformerBackgroundDownload()
    model.selectModelVariant(.transformer)
    try await waitForTransformerDownloadCall(downloadRecorder, count: 1)

    #expect(await downloadRecorder.modes() == [.automatic])
    #expect(model.selectedModelVariant == .transformer)
}

@MainActor
@Test
func cancelledAutomaticTransformerUpdateCannotClearItsReplacement() async throws {
    let suiteName = "SiftTests.modelUpdate.replacement.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    ModelSelectionStore.save(.transformer, defaults: defaults)

    let gate = SuspendedTransformerDownloadGate()
    let channel = TransformerChannelManifestV2(
        releaseSequence: 1,
        releaseID: "signal-v1",
        releaseManifestURL: "https://example.com/release.json",
        releaseManifestSHA256: String(repeating: "a", count: 64),
        modelABI: "sift-signal-v1",
        minimumAppBuild: 1,
        maximumAppBuild: 100,
        minimumOSVersion: "18.0",
        downloadBytes: 100_000_000,
        keyID: "test"
    )
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: SuspendedTransformerDownloader(
            plan: mockTransformerDownloadPlan(
                networkCondition: TransformerNetworkCondition(isConnected: true, usesWiFi: true)
            ),
            gate: gate
        ),
        transformerUpdateChecker: MockTransformerUpdateChecker(state: .updateAvailable(channel)),
        transformerNetworkConditionChecker: MockNetworkConditionChecker(
            condition: TransformerNetworkCondition(isConnected: true, usesWiFi: true),
            recorder: NetworkConditionRecorder()
        ),
        modelClassifierLoader: MockSiftModelClassifierLoader(),
        modelSelectionDefaults: defaults,
        appDefaults: defaults
    )

    try await waitFor {
        model.premium.isEntitlementResolved
            && !model.isSwitchingModelVariant
            && model.selectedModelVariant == .transformer
    }
    model.applicationDidBecomeActive()
    try await waitForSuspendedTransformerDownload(gate, count: 1)

    model.selectModelVariant(.classic)
    try await waitFor {
        !model.isSwitchingModelVariant && model.selectedModelVariant == .classic
    }
    defaults.removeObject(forKey: "Sift.transformerUpdateLastCheck.v1")
    model.selectModelVariant(.transformer)
    try await waitFor {
        !model.isSwitchingModelVariant && model.selectedModelVariant == .transformer
    }
    try await waitForSuspendedTransformerDownload(gate, count: 2)

    await gate.release(1)
    try await Task.sleep(for: .milliseconds(50))
    defaults.removeObject(forKey: "Sift.transformerUpdateLastCheck.v1")
    model.applicationDidBecomeActive()
    try await Task.sleep(for: .milliseconds(50))

    #expect(await gate.count() == 2)
    #expect(model.selectedModelVariant == .transformer)
    await gate.release(2)
}

@MainActor
@Test
func unlockedTransformerSelectionOnMeteredNetworkWaitsForConfirmation() async throws {
    let recorder = TransformerDownloadRecorder()
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: false,
        transformerDownloader: MockTransformerDownloader(
            plan: mockTransformerDownloadPlan(
                networkCondition: TransformerNetworkCondition(isExpensive: true)
            ),
            recorder: recorder
        )
    )
    try await waitForPremiumRefresh(model)

    model.selectModelVariant(.transformer)
    try await waitForTransformerDownloadPhase(model, .waitingForTrafficConfirmation)

    #expect(model.isShowingMeteredTransformerDownloadConfirmation)
    #expect(model.pendingTransformerDownloadPlan?.displayByteCount == 176_160_768)
    #expect(model.meteredTransformerDownloadMessage.contains("168") || model.meteredTransformerDownloadMessage.contains("176"))
    #expect(model.selectedModelVariant == .classic)

    var counts = await recorder.counts()
    #expect(counts.prepare == 1)
    #expect(counts.download == 0)

    model.confirmMeteredTransformerDownload()
    try await waitForTransformerDownloadCall(recorder, count: 1)
    counts = await recorder.counts()
    #expect(counts.download == 1)
}

@MainActor
@Test
func transformerModelLoadingReturnsControlToMainActorImmediately() async throws {
    let suiteName = "SiftTests.modelSelection.nonblocking.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: nil,
        modelClassifierLoader: SlowTransformerClassifierLoader(delay: .milliseconds(200)),
        modelSelectionDefaults: defaults
    )
    try await waitForPremiumRefresh(model)

    let clock = ContinuousClock()
    let startedAt = clock.now
    model.selectModelVariant(.transformer)
    let callDuration = startedAt.duration(to: clock.now)

    #expect(callDuration < .milliseconds(50))
    #expect(model.isSwitchingModelVariant)
    #expect(model.selectedModelVariant == .classic)
    try await waitFor { !model.isSwitchingModelVariant }
    #expect(model.selectedModelVariant == .transformer)
}

@Test
func transformerDownloadAcceptsCurrentCompactManifest() throws {
    let manifest = mockTransformerDownloadPlan().manifest
    try TransformerModelDownloadClient.validateManifestForDownload(manifest)
}

@Test
func transformerDownloadAcceptsQualifiedSift14DistilledManifest() throws {
    try TransformerModelDownloadClient.validateManifestForDownload(sift14DistilledManifest())
}

@Test
func transformerDownloadRejectsUnqualifiedSift14Distillation() {
    let missingProvenance = sift14DistilledManifest(
        algorithm: "supervised-sequence-classification",
        provenance: nil
    )
    #expect(throws: TransformerModelDownloadError.invalidDistillationProvenance) {
        try TransformerModelDownloadClient.validateManifestForDownload(missingProvenance)
    }

    let wrongStudentDepth = sift14DistilledManifest(
        provenance: TransformerDistillationProvenance(
            teacherCheckpointSHA256: String(repeating: "a", count: 64),
            teacherLayers: 22,
            studentLayers: 11,
            temperature: 2,
            distillAlpha: 0.7
        )
    )
    #expect(throws: TransformerModelDownloadError.invalidDistillationProvenance) {
        try TransformerModelDownloadClient.validateManifestForDownload(wrongStudentDepth)
    }
}

@Test
func transformerReleaseSequenceRestartsOnlyAcrossModelABIMigration() {
    #expect(TransformerModelDownloadClient.effectiveCurrentReleaseSequence(
        currentModelABI: "sift-mmbert-v3",
        currentReleaseSequence: 11,
        channelABI: "sift-signal-v1"
    ) == 0)
    #expect(TransformerModelDownloadClient.effectiveCurrentReleaseSequence(
        currentModelABI: "sift-signal-v1",
        currentReleaseSequence: 2,
        channelABI: "sift-signal-v1"
    ) == 2)
}

@Test
func transformerCatalogSelectsLatestReleaseCompatibleWithCurrentAppBuild() throws {
    let release2 = TransformerChannelManifestV2(
        releaseSequence: 2,
        releaseID: "signal-v2-boundary-v15",
        releaseManifestURL: "https://example.com/releases/v15/manifest.json",
        releaseManifestSHA256: String(repeating: "2", count: 64),
        modelABI: "sift-signal-v1",
        minimumAppBuild: 10,
        maximumAppBuild: 15,
        minimumOSVersion: "18.0",
        keyID: "test"
    )
    let release3 = TransformerChannelManifestV2(
        releaseSequence: 3,
        releaseID: "signal-v2-boundary-v16",
        releaseManifestURL: "https://example.com/releases/v16/manifest.json",
        releaseManifestSHA256: String(repeating: "3", count: 64),
        modelABI: "sift-signal-v1",
        minimumAppBuild: 16,
        maximumAppBuild: .max,
        minimumOSVersion: "18.0",
        keyID: "test"
    )
    let release4 = TransformerChannelManifestV2(
        releaseSequence: 4,
        releaseID: "signal-v4-generalization-v50-r32-distilled-12l-metadata-v2",
        releaseManifestURL: "https://example.com/releases/v50-r32-distilled-12l-metadata-v2/manifest.json",
        releaseManifestSHA256: String(repeating: "4", count: 64),
        modelABI: "sift-signal-v1",
        minimumAppBuild: 19,
        maximumAppBuild: .max,
        minimumOSVersion: "18.0",
        keyID: "test"
    )
    let releases = [release2, release3, release4]
    let verifier = TransformerManifestVerifier(publicKeys: [:])
    let iOS18 = OperatingSystemVersion(majorVersion: 18, minorVersion: 0, patchVersion: 0)

    #expect(TransformerModelDownloadClient.latestCompatibleRelease(
        in: releases,
        verifier: verifier,
        appBuild: 15,
        operatingSystemVersion: iOS18,
        currentModelABI: nil,
        currentReleaseSequence: 0
    )?.releaseSequence == 2)
    #expect(TransformerModelDownloadClient.latestCompatibleRelease(
        in: releases,
        verifier: verifier,
        appBuild: 18,
        operatingSystemVersion: iOS18,
        currentModelABI: "sift-signal-v1",
        currentReleaseSequence: 2
    )?.releaseSequence == 3)
    #expect(TransformerModelDownloadClient.latestCompatibleRelease(
        in: releases,
        verifier: verifier,
        appBuild: 19,
        operatingSystemVersion: iOS18,
        currentModelABI: "sift-signal-v1",
        currentReleaseSequence: 3
    )?.releaseSequence == 4)
    #expect(TransformerModelDownloadClient.latestReleaseRequiringAppUpdate(
        in: releases,
        verifier: verifier,
        appBuild: 15,
        operatingSystemVersion: iOS18,
        currentModelABI: "sift-signal-v1",
        currentReleaseSequence: 2
    )?.releaseSequence == 4)
    #expect(TransformerModelDownloadClient.updateState(
        for: releases,
        verifier: verifier,
        appBuild: 15,
        operatingSystemVersion: iOS18,
        currentModelABI: nil,
        currentReleaseSequence: 0
    ) == .updateAvailable(release2))
    #expect(TransformerModelDownloadClient.updateState(
        for: releases,
        verifier: verifier,
        appBuild: 15,
        operatingSystemVersion: iOS18,
        currentModelABI: "sift-signal-v1",
        currentReleaseSequence: 2
    ) == .requiresAppUpdate(release4))
    #expect(TransformerModelDownloadClient.updateState(
        for: releases,
        verifier: verifier,
        appBuild: 18,
        operatingSystemVersion: iOS18,
        currentModelABI: "sift-signal-v1",
        currentReleaseSequence: 2
    ) == .updateAvailable(release3))
    #expect(TransformerModelDownloadClient.updateState(
        for: releases,
        verifier: verifier,
        appBuild: 18,
        operatingSystemVersion: iOS18,
        currentModelABI: "sift-signal-v1",
        currentReleaseSequence: 3
    ) == .requiresAppUpdate(release4))
    #expect(TransformerModelDownloadClient.updateState(
        for: releases,
        verifier: verifier,
        appBuild: 19,
        operatingSystemVersion: iOS18,
        currentModelABI: "sift-signal-v1",
        currentReleaseSequence: 3
    ) == .updateAvailable(release4))
    #expect(TransformerModelDownloadClient.updateState(
        for: releases,
        verifier: verifier,
        appBuild: 19,
        operatingSystemVersion: iOS18,
        currentModelABI: "sift-signal-v1",
        currentReleaseSequence: 4
    ) == .current)
}

@MainActor
@Test
func manualIncompatibleTransformerUpdatePromptsForAppUpdateWithoutReplacingSignal() async throws {
    let suiteName = "SiftTests.modelUpdate.requiresApp.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    ModelSelectionStore.save(.transformer, defaults: defaults)
    defaults.set(Date(), forKey: "Sift.transformerUpdateLastCheck.v1")
    let recorder = TransformerDownloadRecorder()
    let release = TransformerChannelManifestV2(
        releaseSequence: 3,
        releaseID: "signal-v2-boundary-v16",
        releaseManifestURL: "https://example.com/release.json",
        releaseManifestSHA256: String(repeating: "a", count: 64),
        modelABI: "sift-signal-v1",
        minimumAppBuild: 16,
        maximumAppBuild: .max,
        minimumOSVersion: "18.0",
        keyID: "test"
    )
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: MockTransformerDownloader(plan: mockTransformerDownloadPlan(), recorder: recorder),
        transformerUpdateChecker: MockTransformerUpdateChecker(state: .requiresAppUpdate(release)),
        modelClassifierLoader: MockSiftModelClassifierLoader(),
        modelSelectionDefaults: defaults,
        appDefaults: defaults
    )
    try await waitForPremiumRefresh(model)

    model.checkForTransformerUpdate(force: true)
    try await waitFor {
        if case .requiresAppUpdate = model.transformerUpdateState { return true }
        return false
    }
    model.downloadTransformerUpdate()

    #expect(model.isShowingTransformerAppUpdatePrompt)
    #expect(model.selectedModelVariant == .transformer)
    #expect(await recorder.counts().prepare == 0)
    #expect(model.appStoreURL.absoluteString == "https://apps.apple.com/app/id6788805739")
}

@MainActor
@Test
func unknownTransformerUpdateStateBypassesRecentCheckAfterRelaunch() async throws {
    let suiteName = "SiftTests.modelUpdate.relaunchManual.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Date(), forKey: "Sift.transformerUpdateLastCheck.v1")
    let release = TransformerChannelManifestV2(
        releaseSequence: 3,
        releaseID: "signal-v2-boundary-v16",
        releaseManifestURL: "https://example.com/release.json",
        releaseManifestSHA256: String(repeating: "a", count: 64),
        modelABI: "sift-signal-v1",
        minimumAppBuild: 16,
        maximumAppBuild: .max,
        minimumOSVersion: "18.0",
        keyID: "test"
    )
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDeviceSupportOverride: .supported,
        transformerUpdateChecker: MockTransformerUpdateChecker(state: .requiresAppUpdate(release)),
        appDefaults: defaults
    )
    try await waitForPremiumRefresh(model)

    model.checkForTransformerUpdate()
    try await waitFor {
        if case .requiresAppUpdate = model.transformerUpdateState { return true }
        return false
    }
}

@MainActor
@Test
func selectedSignalUnknownUpdateStateBypassesRecentAutomaticCheckAfterRelaunch() async throws {
    let suiteName = "SiftTests.modelUpdate.relaunchAutomatic.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    ModelSelectionStore.save(.transformer, defaults: defaults)
    defaults.set(Date(), forKey: "Sift.transformerUpdateLastCheck.v1")
    let release = TransformerChannelManifestV2(
        releaseSequence: 3,
        releaseID: "signal-v2-boundary-v16",
        releaseManifestURL: "https://example.com/release.json",
        releaseManifestSHA256: String(repeating: "a", count: 64),
        modelABI: "sift-signal-v1",
        minimumAppBuild: 16,
        maximumAppBuild: .max,
        minimumOSVersion: "18.0",
        keyID: "test"
    )
    let networkRecorder = NetworkConditionRecorder()
    let downloadRecorder = TransformerDownloadRecorder()
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDeviceSupportOverride: .supported,
        transformerDownloader: MockTransformerDownloader(
            plan: mockTransformerDownloadPlan(),
            recorder: downloadRecorder
        ),
        transformerUpdateChecker: MockTransformerUpdateChecker(state: .requiresAppUpdate(release)),
        transformerNetworkConditionChecker: MockNetworkConditionChecker(
            condition: TransformerNetworkCondition(isConnected: true, usesWiFi: true),
            recorder: networkRecorder
        ),
        modelClassifierLoader: MockSiftModelClassifierLoader(),
        modelSelectionDefaults: defaults,
        appDefaults: defaults
    )
    try await waitForPremiumRefresh(model)

    if model.selectedModelVariant != .transformer {
        model.selectModelVariant(.transformer)
        try await waitFor {
            model.selectedModelVariant == .transformer && !model.isSwitchingModelVariant
        }
    }
    model.applicationDidBecomeActive()
    try await waitFor {
        if case .requiresAppUpdate = model.transformerUpdateState { return true }
        return false
    }
    #expect(await networkRecorder.callCount == 1)
    #expect(model.selectedModelVariant == .transformer)
}

@MainActor
@Test
func selectedSignalRemainsUsableWhileInteractiveUpdateDownloads() async throws {
    let suiteName = "SiftTests.modelUpdate.selectedSignal.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    ModelSelectionStore.save(.transformer, defaults: defaults)
    defaults.set(Date(), forKey: "Sift.transformerUpdateLastCheck.v1")
    let gate = SuspendedTransformerDownloadGate()
    let release = TransformerChannelManifestV2(
        releaseSequence: 2,
        releaseID: "signal-v2",
        releaseManifestURL: "https://example.com/release.json",
        releaseManifestSHA256: String(repeating: "a", count: 64),
        modelABI: "sift-signal-v1",
        minimumAppBuild: 1,
        maximumAppBuild: .max,
        minimumOSVersion: "18.0",
        keyID: "test"
    )
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: SuspendedTransformerDownloader(plan: mockTransformerDownloadPlan(), gate: gate),
        transformerUpdateChecker: MockTransformerUpdateChecker(state: .updateAvailable(release)),
        modelClassifierLoader: MockSiftModelClassifierLoader(),
        modelSelectionDefaults: defaults,
        appDefaults: defaults
    )
    try await waitForPremiumRefresh(model)
    model.checkForTransformerUpdate(force: true)
    try await waitFor { model.hasCompatibleTransformerUpdate }

    model.downloadTransformerUpdate()
    try await waitForSuspendedTransformerDownload(gate, count: 1)

    #expect(model.selectedModelVariant == .transformer)
    #expect(model.isTransformerDownloadActive)
    #expect(model.isTransformerModelAvailable)

    model.cancelPendingTransformerDownload()
    await gate.release(1)
}

@Test
func transformerDownloadRejectsManifestMissingCompactTokenizerFile() {
    let current = mockTransformerDownloadPlan().manifest
    let manifest = TransformerModelManifest(
        schemaVersion: current.schemaVersion,
        releaseSequence: current.releaseSequence,
        modelABI: current.modelABI,
        minimumAppBuild: current.minimumAppBuild,
        maximumAppBuild: current.maximumAppBuild,
        minimumOSVersion: current.minimumOSVersion,
        runtimeProfile: current.runtimeProfile,
        quantizationProfile: current.quantizationProfile,
        validationMetrics: current.validationMetrics,
        version: current.version,
        trainedAt: current.trainedAt,
        algorithm: current.algorithm,
        backbone: current.backbone,
        languages: current.languages,
        labels: current.labels,
        maxSequenceLength: current.maxSequenceLength,
        doLowerCase: current.doLowerCase,
        tokenizerKind: current.tokenizerKind,
        tokenizerArtifact: current.tokenizerArtifact,
        modelArtifact: current.modelArtifact,
        sha256: current.sha256,
        taxonomyHash: current.taxonomyHash,
        tokenizerSHA256: current.tokenizerSHA256,
        keyID: current.keyID,
        signature: current.signature,
        remoteArtifacts: current.remoteArtifacts.filter { $0.path != current.tokenizerArtifact },
        downloadBytes: current.downloadBytes
    )

    #expect(throws: TransformerModelDownloadError.invalidManifestResponse) {
        try TransformerModelDownloadClient.validateManifestForDownload(manifest)
    }
}

@MainActor
@Test
func storedTransformerStartupLoadsOnlyTransformer() async throws {
    let suiteName = "SiftTests.modelSelection.startup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    ModelSelectionStore.save(.transformer, defaults: defaults)

    let recorder = ModelLoadRecorder()
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: nil,
        modelClassifierLoader: RecordingModelClassifierLoader(recorder: recorder),
        modelSelectionDefaults: defaults,
        appDefaults: defaults
    )

    #expect(model.selectedModelVariant == .transformer)
    #expect(model.isRestoringInitialModelVariant)
    try await waitFor { model.premium.isEntitlementResolved && !model.isSwitchingModelVariant }
    #expect(model.selectedModelVariant == .transformer)
    #expect(!model.isRestoringInitialModelVariant)
    #expect(await recorder.recordedVariants() == [.transformer])
    #expect(defaults.bool(forKey: PremiumStore.cachedEntitlementKey))
}

@MainActor
@Test
func clearingActiveTransformerSwitchesToClassicBeforeRemovingFiles() async throws {
    let suiteName = "SiftTests.modelSelection.cleanup.active.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    ModelSelectionStore.save(.transformer, defaults: defaults)

    let recorder = TransformerRemovalRecorder()
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: nil,
        transformerModelRemover: MockTransformerModelRemover(recorder: recorder),
        modelClassifierLoader: MockSiftModelClassifierLoader(),
        modelSelectionDefaults: defaults
    )
    try await waitForPremiumRefresh(model)
    #expect(model.selectedModelVariant == .transformer)

    model.clearDownloadedTransformerModel()
    #expect(model.isClearingTransformerModel)
    try await waitForTransformerRemovalCall(recorder, count: 1)
    #expect(model.selectedModelVariant == .classic)
    #expect(ModelSelectionStore.load(defaults: defaults) == .classic)
    await recorder.releaseRemoval()
    try await waitFor { !model.isClearingTransformerModel }

    #expect(model.isTransformerModelDownloaded == false)
    #expect(model.toastCenter.toast?.kind == .success)
}

@MainActor
@Test
func transformerCleanupFailureKeepsDownloadedStateAndShowsError() async throws {
    let suiteName = "SiftTests.modelSelection.cleanup.failure.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let recorder = TransformerRemovalRecorder()
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: nil,
        transformerModelRemover: MockTransformerModelRemover(
            recorder: recorder,
            error: .failed
        ),
        modelClassifierLoader: MockSiftModelClassifierLoader(),
        modelSelectionDefaults: defaults
    )
    try await waitForPremiumRefresh(model)

    model.clearDownloadedTransformerModel()
    try await waitForTransformerRemovalCall(recorder, count: 1)
    await recorder.releaseRemoval()
    try await waitFor { !model.isClearingTransformerModel }

    #expect(model.selectedModelVariant == .classic)
    #expect(model.isTransformerModelDownloaded)
    #expect(model.toastCenter.toast?.kind == .error)
}

@MainActor
@Test
func storedTransformerAndMessageFilterRemainSignalUntilExplicitNotPurchased() async throws {
    let suiteName = "SiftTests.modelSelection.entitlement.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 2,
        sha256: "signal-test"
    )
    ModelSelectionStore.save(.transformer, defaults: defaults, artifactIdentity: identity)

    let gate = SuspendedPremiumEntitlementGate()
    let model = SiftAppModel(
        premiumBackend: SuspendedPremiumBackend(gate: gate),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: nil,
        modelClassifierLoader: SlowTransformerClassifierLoader(delay: .seconds(1)),
        modelSelectionDefaults: defaults,
        appDefaults: defaults
    )

    #expect(model.selectedModelVariant == .transformer)
    #expect(model.submissionDestination == .remote)
    #expect(!model.supportsLocalPersonalization)
    #expect(model.isRestoringInitialModelVariant)
    #expect(model.premium.isUnlocked)
    #expect(model.premium.isValidatingEntitlement)
    try await waitForSuspendedPremiumEntitlement(gate, count: 1)

    let snapshotDuringValidation = FilterConfigurationSnapshotStore.load(defaults: defaults)
    #expect(snapshotDuringValidation.selectedVariant == .transformer)
    #expect(snapshotDuringValidation.modelArtifactIdentity == identity)

    let runtimeRecorder = MessageFilterRuntimeRecorder()
    let engine = MessageFilterEngine(
        classicClassifier: HeuristicClassifier(),
        transformerLoader: RecordingMessageFilterRuntimeLoader(recorder: runtimeRecorder),
        transformerDeviceSupport: .supported
    )
    let filterResult = await engine.classify(
        MessageFilterRequest(sender: "10690000", body: "限时优惠"),
        configuration: snapshotDuringValidation
    )
    #expect(filterResult.modelArtifactIdentity == identity)
    #expect(await runtimeRecorder.recordedIdentities() == [identity])
    #expect(model.selectedModelVariant == .transformer)
    #expect(ModelSelectionStore.load(defaults: defaults) == .transformer)

    await gate.resolve(.notPurchased)
    try await waitFor {
        model.premium.isValidatingEntitlement == false
            && model.isSwitchingModelVariant == false
            && model.selectedModelVariant == .classic
    }
    #expect(model.premium.isUnlocked == false)
    #expect(ModelSelectionStore.load(defaults: defaults) == .classic)
    #expect(FilterConfigurationSnapshotStore.load(defaults: defaults).selectedVariant == .classic)
}

@MainActor
@Test
func unverifiedEntitlementKeepsStoredSignalSelectionAndSubmissionUI() async throws {
    let suiteName = "SiftTests.modelSelection.entitlement.unverified.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    ModelSelectionStore.save(.transformer, defaults: defaults)

    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(
            entitled: false,
            outcome: .cancelled,
            entitlementStatusOverride: .unverified
        ),
        transformerAvailabilityOverride: true,
        transformerDownloadedOverride: true,
        transformerDownloader: nil,
        modelClassifierLoader: MockSiftModelClassifierLoader(),
        modelSelectionDefaults: defaults,
        appDefaults: defaults
    )

    #expect(model.selectedModelVariant == .transformer)
    #expect(model.submissionDestination == .remote)
    #expect(!model.supportsLocalPersonalization)
    try await waitFor {
        model.premium.isValidatingEntitlement == false && model.isSwitchingModelVariant == false
    }
    #expect(model.premium.isUnlocked)
    #expect(model.selectedModelVariant == .transformer)
    #expect(model.submissionDestination == .remote)
    #expect(ModelSelectionStore.load(defaults: defaults) == .transformer)
}

@MainActor
@Test
func purchaseOutcomesProduceUserFacingFeedback() async throws {
    let pendingModel = SiftAppModel(premiumBackend: MockPremiumBackend(entitled: false, outcome: .pending))
    let pendingFeedback = await pendingModel.premium.purchase()
    #expect(pendingFeedback?.kind == .info)

    let failedModel = SiftAppModel(premiumBackend: MockPremiumBackend(entitled: false, outcome: .failed("网络错误")))
    let failedFeedback = await failedModel.premium.purchase()
    #expect(failedFeedback?.kind == .error)
    #expect(failedFeedback?.message.contains("网络错误") == true)

    let cancelledModel = SiftAppModel(premiumBackend: MockPremiumBackend(entitled: false, outcome: .cancelled))
    let cancelledFeedback = await cancelledModel.premium.purchase()
    #expect(cancelledFeedback == nil)

    let purchasedModel = SiftAppModel(premiumBackend: MockPremiumBackend(entitled: false, outcome: .purchased))
    let purchasedFeedback = await purchasedModel.premium.purchase()
    #expect(purchasedFeedback?.kind == .success)
    #expect(purchasedModel.premium.isUnlocked)
}

@MainActor
@Test
func missingPremiumPriceUsesFallbackMessage() async throws {
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: false, outcome: .cancelled, product: nil)
    )
    try await waitForPremiumUnavailable(model)

    guard case .unavailable(let message) = model.premium.productState else {
        Issue.record("Expected unavailable premium product state")
        return
    }
    #expect(message == String(localized: "价格信息不可用，请稍后再试"))
}

@MainActor
@Test
func submissionLengthValidationBlocksOverlongSamples() {
    let model = SiftAppModel(
        remoteSampleClient: nil,
        premiumBackend: MockPremiumBackend(entitled: false, outcome: .cancelled)
    )
    model.submissionText = String(repeating: "很长的样本", count: 120)

    #expect(!model.canSubmitSample)
    #expect(model.submissionValidationMessage?.contains("过长") == true)

    model.submissionText = "正常长度的样本文本"
    #expect(model.submissionValidationMessage == nil)
}

@MainActor
private func waitForPremiumRefresh(_ model: SiftAppModel) async throws {
    for _ in 0..<100 {
        if case .available = model.premium.productState, !model.isSwitchingModelVariant {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor
private func waitForPremiumUnavailable(_ model: SiftAppModel) async throws {
    for _ in 0..<100 {
        if case .unavailable = model.premium.productState {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for premium unavailable state")
}

@MainActor
private func waitForTransformerDownloadPhase(
    _ model: SiftAppModel,
    _ phase: TransformerModelDownloadPhase
) async throws {
    for _ in 0..<100 {
        if model.transformerDownloadPhase == phase {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for transformer download phase \(phase)")
}

@MainActor
private func waitForTransformerDownloadCall(
    _ recorder: TransformerDownloadRecorder,
    count: Int
) async throws {
    for _ in 0..<100 {
        if await recorder.counts().download >= count {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for transformer download call")
}

private func waitForSuspendedTransformerDownload(
    _ gate: SuspendedTransformerDownloadGate,
    count: Int
) async throws {
    for _ in 0..<100 {
        if await gate.count() >= count {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for suspended transformer download")
}

private func waitForTransformerRemovalCall(
    _ recorder: TransformerRemovalRecorder,
    count: Int
) async throws {
    for _ in 0..<100 {
        if await recorder.callCount >= count {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for transformer removal call")
}

private func waitForNetworkConditionCheck(
    _ recorder: NetworkConditionRecorder,
    count: Int
) async throws {
    for _ in 0..<100 {
        if await recorder.callCount >= count {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for network condition check")
}

private func waitForPremiumEntitlementCheck(
    _ recorder: PremiumEntitlementRecorder,
    count: Int
) async throws {
    for _ in 0..<100 {
        if await recorder.callCount() >= count {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for premium entitlement check")
}

private func waitForSuspendedPremiumEntitlement(
    _ gate: SuspendedPremiumEntitlementGate,
    count: Int
) async throws {
    for _ in 0..<100 {
        if await gate.count() >= count {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for suspended premium entitlement check")
}

// MARK: - Submission history paging

@MainActor
@Test
func submissionHistoryPagesDeduplicatesAndDeletesSingleItems() async throws {
    let suiteName = "SiftTests.ledger.history.\(UUID().uuidString)"
    let ledgerDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer { ledgerDefaults.removePersistentDomain(forName: suiteName) }
    ledgerDefaults.set(45, forKey: "Sift.submittedSampleCount")

    let seeded = (0..<45).map { index in
        RemoteSubmissionSummary(
            recordName: "record-\(index)",
            text: "样本内容 \(index)",
            label: "spam",
            submittedAt: nil,
            createdAtMillis: Int64(100_000 - index)
        )
    }
    let client = MockRemoteSampleClient(result: .success("unused"), seededHistory: seeded)
    let model = SiftAppModel(
        remoteSampleClient: client,
        premiumBackend: MockPremiumBackend(entitled: false, outcome: .cancelled),
        ledgerDefaults: ledgerDefaults
    )
    #expect(model.submittedSampleCount == 45)

    model.loadMoreSubmissionHistory()
    try await waitFor { !model.isLoadingHistory && !model.submissionHistory.isEmpty }
    #expect(model.submissionHistory.count == SiftAppModel.historyPageSize)
    #expect(!model.historyFullyLoaded)
    #expect(model.submissionHistory.first?.recordName == "record-0")
    #expect(model.submittedSampleCount == 45)

    model.loadMoreSubmissionHistory()
    try await waitFor { model.historyFullyLoaded }
    #expect(model.submissionHistory.count == 45)
    // 去重:重复触发不应该增加条目。
    model.loadMoreSubmissionHistory()
    #expect(model.submissionHistory.count == 45)

    let victim = model.submissionHistory[3]
    let countBefore = model.submittedSampleCount
    model.deleteSubmission(victim)
    try await waitFor { model.submissionHistory.count == 44 }
    #expect(!model.submissionHistory.contains { $0.recordName == victim.recordName })
    #expect(model.submittedSampleCount == countBefore - 1)
}

@MainActor
@Test
func shortFirstHistoryBatchDoesNotOverwriteIndependentSubmissionCount() async throws {
    let suiteName = "SiftTests.ledger.shortHistoryBatch.\(UUID().uuidString)"
    let ledgerDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer { ledgerDefaults.removePersistentDomain(forName: suiteName) }
    SubmissionLedger.set(20, defaults: ledgerDefaults)

    let seeded = (0..<20).map { index in
        RemoteSubmissionSummary(
            recordName: "record-\(index)",
            text: "样本内容 \(index)",
            label: "spam",
            submittedAt: nil,
            createdAtMillis: Int64(100_000 - index)
        )
    }
    let client = MockRemoteSampleClient(
        result: .success("unused"),
        seededHistory: seeded,
        historyPageCap: 2
    )
    let model = SiftAppModel(
        remoteSampleClient: client,
        premiumBackend: MockPremiumBackend(entitled: false, outcome: .cancelled),
        ledgerDefaults: ledgerDefaults
    )

    model.refreshSubmissionHistoryIfNeeded()
    try await waitFor {
        !model.isLoadingHistory && model.submissionHistory.count == 2
    }

    #expect(model.submittedSampleCount == 20)
    #expect(SubmissionLedger.count(defaults: ledgerDefaults) == 20)
}

@MainActor
@Test
func cachedSubmissionHistoryRestoresRowsAndCounterWithoutFetching() throws {
    let suiteName = "SiftTests.history.cache.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let cached = RemoteSubmissionSummary(
        recordName: "cached-record",
        text: "已脱敏的缓存样本",
        label: "spam",
        submittedAt: Date(timeIntervalSince1970: 1_788_840_000),
        createdAtMillis: 1_788_840_000_000
    )
    SubmissionHistoryCache.save(
        SubmissionHistoryCacheSnapshot(submissions: [cached], fullyLoaded: true),
        defaults: defaults
    )
    SubmissionLedger.set(7, defaults: defaults)

    let model = SiftAppModel(
        remoteSampleClient: MockRemoteSampleClient(result: .failure(RemoteSampleClientError.noAccount)),
        premiumBackend: MockPremiumBackend(entitled: false, outcome: .cancelled),
        ledgerDefaults: defaults
    )

    #expect(model.hasLoadedSubmissionHistory)
    #expect(model.historyFullyLoaded)
    #expect(model.submissionHistory == [cached])
    #expect(model.submittedSampleCount == 7)
    #expect(SubmissionLedger.count(defaults: defaults) == 7)
}

@MainActor
@Test
func failedOptimisticSubmissionDeletionRestoresCacheAndCounter() async throws {
    let suiteName = "SiftTests.history.deleteRollback.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let cached = RemoteSubmissionSummary(
        recordName: "rollback-record",
        text: "回滚样本",
        label: "promotion",
        submittedAt: nil,
        createdAtMillis: 123
    )
    SubmissionHistoryCache.save(
        SubmissionHistoryCacheSnapshot(submissions: [cached], fullyLoaded: true),
        defaults: defaults
    )
    SubmissionLedger.set(1, defaults: defaults)
    let model = SiftAppModel(
        remoteSampleClient: MockRemoteSampleClient(result: .failure(RemoteSampleClientError.noAccount)),
        premiumBackend: MockPremiumBackend(entitled: false, outcome: .cancelled),
        ledgerDefaults: defaults
    )

    model.deleteSubmission(cached)
    #expect(model.submissionHistory.isEmpty)
    #expect(model.submittedSampleCount == 0)

    try await waitFor {
        model.submissionHistory == [cached] && model.toastCenter.toast?.kind == .error
    }
    #expect(model.submittedSampleCount == 1)
    #expect(SubmissionHistoryCache.load(defaults: defaults)?.submissions == [cached])
}

@MainActor
@Test
func failedOptimisticEraseAllRestoresCacheAndCounter() async throws {
    let suiteName = "SiftTests.history.eraseRollback.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let cached = RemoteSubmissionSummary(
        recordName: "erase-rollback-record",
        text: "清空回滚样本",
        label: "spam",
        submittedAt: nil,
        createdAtMillis: 456
    )
    SubmissionHistoryCache.save(
        SubmissionHistoryCacheSnapshot(submissions: [cached], fullyLoaded: true),
        defaults: defaults
    )
    SubmissionLedger.set(1, defaults: defaults)
    let model = SiftAppModel(
        remoteSampleClient: MockRemoteSampleClient(result: .failure(RemoteSampleClientError.noAccount)),
        premiumBackend: MockPremiumBackend(entitled: false, outcome: .cancelled),
        ledgerDefaults: defaults
    )

    model.eraseAllRemoteData()
    #expect(model.submissionHistory.isEmpty)
    #expect(model.submittedSampleCount == 0)

    try await waitFor {
        model.submissionHistory == [cached] && model.isErasingRemoteData == false
    }
    #expect(model.submittedSampleCount == 1)
    #expect(SubmissionHistoryCache.load(defaults: defaults)?.submissions == [cached])
}

@MainActor
@Test
func cachedHistoryRefreshesOnlyAfterTheRefreshInterval() async throws {
    let suiteName = "SiftTests.history.ttl.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let updatedAt = Date(timeIntervalSince1970: 1_788_840_000)
    let cached = RemoteSubmissionSummary(
        recordName: "cached-record",
        text: "缓存样本",
        label: "spam",
        submittedAt: nil,
        createdAtMillis: 100
    )
    let refreshed = RemoteSubmissionSummary(
        recordName: "refreshed-record",
        text: "刷新样本",
        label: "promotion",
        submittedAt: nil,
        createdAtMillis: 200
    )
    SubmissionHistoryCache.save(
        SubmissionHistoryCacheSnapshot(
            submissions: [cached],
            fullyLoaded: false,
            updatedAt: updatedAt
        ),
        defaults: defaults
    )
    SubmissionLedger.set(5, defaults: defaults)
    let client = MockRemoteSampleClient(result: .success("unused"), seededHistory: [refreshed])
    let model = SiftAppModel(
        remoteSampleClient: client,
        premiumBackend: MockPremiumBackend(entitled: false, outcome: .cancelled),
        ledgerDefaults: defaults
    )
    #expect(model.submittedSampleCount == 5)

    model.refreshSubmissionHistoryIfNeeded(
        now: updatedAt.addingTimeInterval(SiftAppModel.historyCacheRefreshInterval - 1)
    )
    try await Task.sleep(nanoseconds: 10_000_000)
    #expect(await client.recorder.historyFetchCount == 0)

    model.refreshSubmissionHistoryIfNeeded(
        now: updatedAt.addingTimeInterval(SiftAppModel.historyCacheRefreshInterval)
    )
    try await waitFor { model.submissionHistory == [refreshed] }
    #expect(await client.recorder.historyFetchCount == 1)
    #expect(model.submittedSampleCount == 1)
    #expect(SubmissionLedger.count(defaults: defaults) == 1)
}

@MainActor
@Test
func concurrentOptimisticDeletionsKeepTheSuccessfulDeletionApplied() async throws {
    let suiteName = "SiftTests.history.concurrentDeletion.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let failed = RemoteSubmissionSummary(
        recordName: "fails",
        text: "应回滚",
        label: "spam",
        submittedAt: nil,
        createdAtMillis: 200
    )
    let succeeded = RemoteSubmissionSummary(
        recordName: "succeeds",
        text: "应删除",
        label: "promotion",
        submittedAt: nil,
        createdAtMillis: 100
    )
    SubmissionHistoryCache.save(
        SubmissionHistoryCacheSnapshot(submissions: [failed, succeeded], fullyLoaded: true),
        defaults: defaults
    )
    SubmissionLedger.set(2, defaults: defaults)
    let model = SiftAppModel(
        remoteSampleClient: SelectiveDeletionClient(),
        premiumBackend: MockPremiumBackend(entitled: false, outcome: .cancelled),
        ledgerDefaults: defaults
    )

    model.deleteSubmission(failed)
    model.deleteSubmission(succeeded)

    try await waitFor {
        model.submissionHistory == [failed] && model.submittedSampleCount == 1
    }
    #expect(SubmissionLedger.count(defaults: defaults) == 1)
}

@MainActor
private func waitFor(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for condition")
}
#endif
