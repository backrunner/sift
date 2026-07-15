#if canImport(Testing)
import Foundation
import MessageFilterCore
import SiftAppKit
import Testing

// MARK: - Premium gating

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

    func loadProduct(identifier: String) async throws -> PremiumProductInfo? {
        if let loadError {
            throw loadError
        }
        return product
    }

    func purchase(identifier: String) async -> PremiumPurchaseOutcome {
        outcome
    }

    func isEntitled(identifier: String) async -> Bool {
        entitled
    }

    func restore(identifier: String) async throws -> Bool {
        entitled
    }

    func entitlementUpdates(identifier: String) -> AsyncStream<Bool> {
        AsyncStream { $0.finish() }
    }
}

private actor TransformerDownloadRecorder {
    private(set) var prepareCallCount = 0
    private(set) var downloadCallCount = 0

    func recordPrepare() {
        prepareCallCount += 1
    }

    func recordDownload() {
        downloadCallCount += 1
    }

    func counts() -> (prepare: Int, download: Int) {
        (prepareCallCount, downloadCallCount)
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
        progress: @Sendable @escaping (TransformerModelDownloadProgress) -> Void
    ) async throws {
        await recorder.recordDownload()
        progress(TransformerModelDownloadProgress(receivedBytes: plan.displayByteCount ?? 1, totalBytes: plan.displayByteCount))
    }
}

private func mockTransformerDownloadPlan(
    networkCondition: TransformerNetworkCondition = TransformerNetworkCondition()
) -> TransformerModelDownloadPlan {
    let manifest = TransformerModelManifest(
        version: "remote-0.1",
        trainedAt: "2026-07-07T08:00:00.000Z",
        algorithm: "supervised-sequence-classification",
        backbone: "jhu-clsp/mmBERT-small",
        languages: ["zh", "en", "ja"],
        labels: ["spam", "promotion"],
        maxSequenceLength: 8,
        doLowerCase: false,
        tokenizerKind: "bpe",
        tokenizerArtifact: "SiftTransformerClassifier.tokenizer.json",
        modelArtifact: "SiftTransformerClassifier.mlpackage",
        remoteArtifacts: [
            TransformerRemoteArtifact(
                path: "SiftTransformerClassifier.tokenizer.json",
                sha256: nil,
                byteCount: 1024
            )
        ],
        downloadBytes: 176_160_768
    )
    return TransformerModelDownloadPlan(
        manifest: manifest,
        manifestURL: URL(string: "https://example.com/SiftTransformerClassifier.manifest.json")!,
        artifacts: [
            TransformerModelDownloadArtifact(
                remoteURL: URL(string: "https://example.com/SiftTransformerClassifier.tokenizer.json")!,
                relativePath: "SiftTransformerClassifier.tokenizer.json",
                byteCount: 1024
            )
        ],
        exactByteCount: 176_160_768,
        estimatedByteCount: nil,
        networkCondition: networkCondition
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
        if case .available = model.premium.productState {
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
    #expect(model.submittedSampleCount == 1)
    #expect(SubmissionLedger.count(defaults: defaults) == 1)
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
        model.submissionHistory == [cached] && model.currentToast?.kind == .error
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
