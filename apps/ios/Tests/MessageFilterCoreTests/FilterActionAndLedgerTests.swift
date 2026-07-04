#if canImport(Testing)
import Foundation
import MessageFilterCore
import MessageFilterExtensionKit
import Testing

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
