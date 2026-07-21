#if canImport(Testing)
import Foundation
import MessageFilterCore
import MessageFilterExtensionKit
import Testing

private final class CompletionValueRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Test
func completionOnceGateCompletesExactlyOnceUnderContention() async {
    let recorder = CompletionValueRecorder()
    let gate = CompletionOnceGate<Int> { recorder.record($0) }

    let winnerCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for value in 0..<100 {
            group.addTask {
                gate.complete(value)
            }
        }
        var count = 0
        for await didComplete in group where didComplete {
            count += 1
        }
        return count
    }

    #expect(winnerCount == 1)
    #expect(recorder.snapshot().count == 1)
}

@Test
func messageFilterDiagnosticsContainNoMessageContentFields() throws {
    let event = MessageFilterDiagnosticEvent(
        artifactIdentity: .classic,
        latencyBucket: .under150Milliseconds,
        fallbackReason: .none
    )

    let json = try #require(String(data: JSONEncoder().encode(event), encoding: .utf8))
    #expect(!json.contains("sender"))
    #expect(!json.contains("body"))
}

@Test
func messageFilterSessionTrackerMarksOnlyTheFirstQueryCold() async {
    let tracker = MessageFilterSessionTracker()
    let coldCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for _ in 0..<100 {
            group.addTask { tracker.beginQuery() }
        }
        var count = 0
        for await isCold in group where isCold {
            count += 1
        }
        return count
    }

    #expect(coldCount == 1)
}

@Test
func messageFilterPerformanceEvidenceAggregatesWithoutMessageContent() throws {
    let suiteName = "SiftTests.messageFilterEvidence.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = MessageFilterPerformanceEvidenceStore(defaults: defaults)
    let requested = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 9,
        sha256: String(repeating: "a", count: 64)
    )

    store.record(MessageFilterDiagnosticEvent(
        artifactIdentity: .classic,
        latencyBucket: .under600Milliseconds,
        fallbackReason: .transformerTimedOut,
        requestedArtifactIdentity: requested,
        isColdStart: true,
        physicalFootprintBytes: 100
    ))
    store.record(MessageFilterDiagnosticEvent(
        artifactIdentity: requested,
        latencyBucket: .under150Milliseconds,
        fallbackReason: .none,
        errorCode: "handler_watchdog",
        requestedArtifactIdentity: requested,
        physicalFootprintBytes: 124
    ))

    let snapshot = store.snapshot()
    let release = try #require(snapshot.releases.values.first)
    #expect(snapshot.schemaVersion == 1)
    #expect(snapshot.releases.count == 1)
    #expect(release.requestedArtifactIdentity == requested)
    #expect(release.coldRunCount == 1)
    #expect(release.warmQueryCount == 1)
    #expect(release.coldLatencyBuckets[MessageFilterLatencyBucket.under600Milliseconds.rawValue] == 1)
    #expect(release.warmLatencyBuckets[MessageFilterLatencyBucket.under150Milliseconds.rawValue] == 1)
    #expect(release.fallbackCounts[MessageFilterFallbackReason.transformerTimedOut.rawValue] == 1)
    #expect(release.watchdogCount == 1)
    #expect(release.firstPhysicalFootprintBytes == 100)
    #expect(release.latestPhysicalFootprintBytes == 124)
    #expect(release.peakPhysicalFootprintBytes == 124)
    #expect(release.memoryDriftBytes == 24)

    let json = try #require(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
    #expect(!json.contains("sender"))
    #expect(!json.contains("body"))
    store.reset()
    #expect(store.snapshot().releases.isEmpty)
}

// MARK: - Filter action mapping (核心过滤行为)

private func decision(action: SystemAction, confidence: Double) -> ClassificationDecision {
    ClassificationDecision(
        labelID: "spam",
        labelTitle: "spam",
        groupID: "spam",
        groupTitle: "spam",
        confidence: confidence,
        systemAction: action,
        source: .model
    )
}

private struct ExpectedSystemMapping: Sendable {
    let labelID: String
    let action: SystemAction
    let subAction: SystemSubAction
}

private let expectedSystemMappings: [ExpectedSystemMapping] = [
    .init(labelID: "finance.bank", action: .transaction, subAction: .transactionalFinance),
    .init(labelID: "finance.insurance", action: .transaction, subAction: .transactionalFinance),
    .init(labelID: "finance.wealth", action: .transaction, subAction: .transactionalFinance),
    .init(labelID: "finance.credit_card", action: .transaction, subAction: .transactionalFinance),
    .init(labelID: "finance.consumption", action: .transaction, subAction: .transactionalFinance),
    .init(labelID: "finance.income", action: .transaction, subAction: .transactionalFinance),
    .init(labelID: "finance.refund", action: .transaction, subAction: .transactionalFinance),
    .init(labelID: "finance.stock", action: .transaction, subAction: .transactionalFinance),
    .init(labelID: "finance.other", action: .transaction, subAction: .transactionalFinance),
    .init(labelID: "transaction.order", action: .transaction, subAction: .transactionalOrders),
    .init(labelID: "transaction.points", action: .transaction, subAction: .transactionalRewards),
    .init(labelID: "transaction.member", action: .transaction, subAction: .transactionalRewards),
    .init(labelID: "transaction.message", action: .transaction, subAction: .transactionalOthers),
    .init(labelID: "transaction.account_security", action: .transaction, subAction: .transactionalOthers),
    .init(labelID: "transaction.other", action: .transaction, subAction: .transactionalOthers),
    .init(labelID: "life.takeaway", action: .transaction, subAction: .transactionalOrders),
    .init(labelID: "life.express", action: .transaction, subAction: .transactionalOrders),
    .init(labelID: "life.utility", action: .transaction, subAction: .transactionalOthers),
    .init(labelID: "life.logistics", action: .transaction, subAction: .transactionalOrders),
    .init(labelID: "life.pickup_code", action: .transaction, subAction: .transactionalOrders),
    .init(labelID: "life.medical", action: .transaction, subAction: .transactionalHealth),
    .init(labelID: "life.weather", action: .transaction, subAction: .transactionalWeather),
    .init(labelID: "life.other", action: .transaction, subAction: .transactionalOthers),
    .init(labelID: "travel.tourism", action: .transaction, subAction: .transactionalOthers),
    .init(labelID: "travel.transport", action: .transaction, subAction: .transactionalReminders),
    .init(labelID: "travel.ticketing", action: .transaction, subAction: .transactionalOrders),
    .init(labelID: "travel.other", action: .transaction, subAction: .transactionalOthers),
    .init(labelID: "work.meeting", action: .transaction, subAction: .transactionalReminders),
    .init(labelID: "work.approval", action: .transaction, subAction: .transactionalOthers),
    .init(labelID: "work.attendance", action: .transaction, subAction: .transactionalOthers),
    .init(labelID: "work.announcement", action: .transaction, subAction: .transactionalOthers),
    .init(labelID: "work.training", action: .transaction, subAction: .transactionalReminders),
    .init(labelID: "work.reminder", action: .transaction, subAction: .transactionalReminders),
    .init(labelID: "work.alert", action: .transaction, subAction: .transactionalOthers),
    .init(labelID: "work.other", action: .transaction, subAction: .transactionalOthers),
    .init(labelID: "carrier.call_reminder", action: .transaction, subAction: .transactionalCarrier),
    .init(labelID: "carrier.data_reminder", action: .transaction, subAction: .transactionalCarrier),
    .init(labelID: "carrier.service", action: .transaction, subAction: .transactionalCarrier),
    .init(labelID: "carrier.promotion", action: .promotion, subAction: .promotionalOffers),
    .init(labelID: "carrier.other", action: .transaction, subAction: .transactionalCarrier),
    .init(labelID: "government.notice", action: .transaction, subAction: .transactionalPublicServices),
    .init(labelID: "government.traffic", action: .transaction, subAction: .transactionalPublicServices),
    .init(labelID: "government.tax", action: .transaction, subAction: .transactionalPublicServices),
    .init(labelID: "government.social_security", action: .transaction, subAction: .transactionalPublicServices),
    .init(labelID: "government.court", action: .transaction, subAction: .transactionalPublicServices),
    .init(labelID: "government.policy", action: .transaction, subAction: .transactionalPublicServices),
    .init(labelID: "government.other", action: .transaction, subAction: .transactionalPublicServices),
    .init(labelID: "verification", action: .transaction, subAction: .transactionalOthers),
    .init(labelID: "promotion", action: .promotion, subAction: .promotionalOffers),
    .init(labelID: "spam", action: .junk, subAction: .none)
]

private func taxonomyDecision(
    labelID: String,
    confidence: Double = 0.9,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> ClassificationDecision {
    let leaf = try #require(SiftTaxonomy.leaf(id: labelID), sourceLocation: sourceLocation)
    return ClassificationDecision(
        labelID: leaf.id,
        labelTitle: leaf.title,
        groupID: leaf.groupId,
        groupTitle: leaf.groupTitle,
        confidence: confidence,
        systemAction: leaf.systemAction,
        source: .model
    )
}

@Test
func junkAndPromotionAlwaysMapRegardlessOfConfidence() {
    #expect(MessageFilterActionMapper.systemAction(for: decision(action: .junk, confidence: 0.2)) == .junk)
    #expect(MessageFilterActionMapper.systemAction(for: decision(action: .promotion, confidence: 0.2)) == .promotion)
}

@Test
func lowConfidenceTransactionFallsBackToAllow() {
    // 低置信不该把消息硬塞进"交易"分栏 —— 宁可放行。
    #expect(MessageFilterActionMapper.systemAction(for: decision(action: .transaction, confidence: 0.5)) == .none)
    #expect(MessageFilterActionMapper.systemAction(for: decision(action: .transaction, confidence: 0.65)) == .transaction)
    #expect(MessageFilterActionMapper.systemAction(for: decision(action: .none, confidence: 0.99)) == .none)
}

@Test
func taxonomyLeavesMapToExpectedSystemActionsAndSubActions() throws {
    #expect(expectedSystemMappings.count == SiftTaxonomy.leaves.count)

    for expected in expectedSystemMappings {
        let decision = try taxonomyDecision(labelID: expected.labelID)
        #expect(
            MessageFilterActionMapper.systemAction(for: decision) == expected.action,
            "\(expected.labelID) should map to \(expected.action.rawValue)"
        )
        #expect(
            MessageFilterActionMapper.systemSubAction(for: decision) == expected.subAction,
            "\(expected.labelID) should map to \(expected.subAction.rawValue)"
        )
    }
}

@Test
func lowConfidenceTransactionHasNoSubAction() throws {
    let decision = try taxonomyDecision(labelID: "finance.bank", confidence: 0.5)

    #expect(MessageFilterActionMapper.systemAction(for: decision) == .none)
    #expect(MessageFilterActionMapper.systemSubAction(for: decision) == .none)
}

@Test
func carrierPromotionIsPromotionEvenWhenStoredUnderCarrierGroup() throws {
    let decision = try taxonomyDecision(labelID: "carrier.promotion")

    #expect(decision.groupID == "carrier")
    #expect(decision.systemAction == .promotion)
    #expect(MessageFilterActionMapper.systemAction(for: decision) == .promotion)
    #expect(MessageFilterActionMapper.systemSubAction(for: decision) == .promotionalOffers)
}

@Test
func categoryMappingPersistsAndOverridesFinalSystemAction() throws {
    let suiteName = "SiftTests.categoryMapping.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let mappings: [String: CategoryMappingTarget] = [
        "finance.bank": .junk,
        "life.express": .promotion
    ]

    SharedCategoryMappingStore.save(mappings, defaults: defaults)
    let loaded = SharedCategoryMappingStore.load(defaults: defaults)
    let bank = try taxonomyDecision(labelID: "finance.bank")
        .applying(categoryMappings: loaded)
    let express = try taxonomyDecision(labelID: "life.express")
        .applying(categoryMappings: loaded)

    #expect(loaded == mappings)
    #expect(MessageFilterActionMapper.systemAction(for: bank) == .junk)
    #expect(MessageFilterActionMapper.systemSubAction(for: bank) == .none)
    #expect(MessageFilterActionMapper.systemAction(for: express) == .promotion)
    #expect(MessageFilterActionMapper.systemSubAction(for: express) == .promotionalOthers)
}

@Test
func categoryMappingTargetsCannotBeMappingSources() throws {
    let suiteName = "SiftTests.categoryMappingTargets.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let mappings: [String: CategoryMappingTarget] = [
        "promotion": .junk,
        "spam": .promotion,
        "carrier.promotion": .junk
    ]

    SharedCategoryMappingStore.save(mappings, defaults: defaults)
    let loaded = SharedCategoryMappingStore.load(defaults: defaults)
    let promotion = try taxonomyDecision(labelID: "promotion")
        .applying(categoryMappings: mappings)
    let spam = try taxonomyDecision(labelID: "spam")
        .applying(categoryMappings: mappings)

    #expect(!CategoryMappingPolicy.isEligibleSource(labelID: "promotion"))
    #expect(!CategoryMappingPolicy.isEligibleSource(labelID: "spam"))
    #expect(CategoryMappingPolicy.isEligibleSource(labelID: "carrier.promotion"))
    #expect(loaded == ["carrier.promotion": .junk])
    #expect(promotion.systemAction == .promotion)
    #expect(spam.systemAction == .junk)
}

// MARK: - SubmissionLedger

@Test
func submissionLedgerCountsUpDownAndResets() throws {
    let suiteName = "SiftTests.ledger.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(SubmissionLedger.count(defaults: defaults) == 0)
    SubmissionLedger.increment(defaults: defaults)
    SubmissionLedger.increment(defaults: defaults)
    #expect(SubmissionLedger.count(defaults: defaults) == 2)
    SubmissionLedger.decrement(defaults: defaults)
    #expect(SubmissionLedger.count(defaults: defaults) == 1)
    SubmissionLedger.decrement(defaults: defaults)
    SubmissionLedger.decrement(defaults: defaults)
    #expect(SubmissionLedger.count(defaults: defaults) == 0, "计数不允许为负")
    SubmissionLedger.increment(defaults: defaults)
    SubmissionLedger.reset(defaults: defaults)
    #expect(SubmissionLedger.count(defaults: defaults) == 0)
}
#endif
