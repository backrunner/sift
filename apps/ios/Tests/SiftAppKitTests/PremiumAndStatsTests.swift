#if canImport(Testing)
import Foundation
import MessageFilterCore
import SiftAppKit
import Testing

// MARK: - FilterStatisticsStore

@MainActor
@Test
func statisticsStoreCountsByActionAndGroup() throws {
    let suiteName = "SiftTests.stats.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = FilterStatisticsStore(defaults: defaults)

    let junk = decision(labelID: "spam", groupID: "spam", action: .junk)
    let promo = decision(labelID: "promotion", groupID: "promotion", action: .promotion)
    let normal = decision(labelID: "verification", groupID: "verification", action: .transaction)

    store.record(decision: junk)
    store.record(decision: junk)
    store.record(decision: promo)
    store.record(decision: normal)

    let today = store.stats()
    #expect(today.total == 4)
    #expect(today.junk == 2)
    #expect(today.promotion == 1)
    #expect(today.transaction == 1)
    #expect(today.byGroup["spam"] == 2)

    let week = store.recent(days: 7)
    #expect(week.count == 7)
    #expect(week.last?.total == 4)
    #expect(week.first?.total == 0)
}

@Test
func dailyStatsMergeTakesPerCounterMax() {
    var local = DailyFilterStats(day: "2026-07-05", total: 10, junk: 4, promotion: 2, transaction: 4, byGroup: ["spam": 4])
    let remote = DailyFilterStats(day: "2026-07-05", total: 8, junk: 6, promotion: 1, transaction: 1, byGroup: ["spam": 6, "life": 2])

    local = local.merged(with: remote)
    #expect(local.total == 10)
    #expect(local.junk == 6)
    #expect(local.promotion == 2)
    #expect(local.byGroup["spam"] == 6)
    #expect(local.byGroup["life"] == 2)
}

private func decision(labelID: String, groupID: String, action: SystemAction) -> ClassificationDecision {
    ClassificationDecision(
        labelID: labelID,
        labelTitle: labelID,
        groupID: groupID,
        groupTitle: groupID,
        confidence: 0.9,
        systemAction: action,
        source: .model
    )
}

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

private struct MockTransformerDownloader: TransformerModelDownloading {
    let plan: TransformerModelDownloadPlan

    func prepareDownload() async throws -> TransformerModelDownloadPlan {
        plan
    }

    func download(
        _ plan: TransformerModelDownloadPlan,
        progress: @Sendable @escaping (TransformerModelDownloadProgress) -> Void
    ) async throws {
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
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: false,
        transformerDownloader: MockTransformerDownloader(plan: mockTransformerDownloadPlan())
    )
    try await waitForPremiumRefresh(model)

    #expect(model.premium.isUnlocked)
    #expect(model.transformerDownloadPhase == .notDownloaded)
    #expect(model.selectedModelVariant == .classic)
}

@MainActor
@Test
func unlockedTransformerSelectionOnMeteredNetworkWaitsForConfirmation() async throws {
    let model = SiftAppModel(
        premiumBackend: MockPremiumBackend(entitled: true, outcome: .cancelled),
        transformerAvailabilityOverride: false,
        transformerDownloader: MockTransformerDownloader(
            plan: mockTransformerDownloadPlan(
                networkCondition: TransformerNetworkCondition(isExpensive: true)
            )
        )
    )
    try await waitForPremiumRefresh(model)

    model.selectModelVariant(.transformer)
    try await waitForTransformerDownloadPhase(model, .waitingForTrafficConfirmation)

    #expect(model.isShowingMeteredTransformerDownloadConfirmation)
    #expect(model.pendingTransformerDownloadPlan?.displayByteCount == 176_160_768)
    #expect(model.meteredTransformerDownloadMessage.contains("168") || model.meteredTransformerDownloadMessage.contains("176"))
    #expect(model.selectedModelVariant == .classic)
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
