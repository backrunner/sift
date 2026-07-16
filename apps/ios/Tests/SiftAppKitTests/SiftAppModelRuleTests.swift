#if canImport(Testing)
import Foundation
import MessageFilterCore
import SiftAppKit
import Testing

private let remoteSamplePrivacyConsentKey = "Sift.hasAcceptedRemoteSamplePrivacy"

@MainActor
@Test
func ruleAddEditToggleAndDeletePersistAcrossModelInstances() throws {
    let suiteName = "SiftTests.rules.persistence.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let model = SiftAppModel(ruleDefaults: defaults)
    #expect(model.rules.isEmpty)

    model.ruleDraftName = "Pickup code"
    model.ruleDraftLocation = .body
    model.ruleDraftPatternKind = .substring
    model.ruleDraftPattern = "取件码"
    model.ruleDraftAction = .block

    #expect(model.addCustomRuleFromDraft())
    let addedRule = try #require(model.rules.first)
    #expect(addedRule.name == "Pickup code")
    #expect(addedRule.text?.pattern == "取件码")
    #expect(addedRule.action == .block)

    let reloadedAfterAdd = SiftAppModel(ruleDefaults: defaults)
    let persistedAddedRule = try #require(reloadedAfterAdd.rules.first)
    #expect(persistedAddedRule.id == addedRule.id)
    #expect(persistedAddedRule.text?.pattern == "取件码")

    #expect(reloadedAfterAdd.updateRule(
        id: addedRule.id,
        name: "Bank sender",
        location: .sender,
        patternKind: .regex,
        pattern: "^955\\d{2}$",
        action: .allow
    ))

    let editedRule = try #require(reloadedAfterAdd.rules.first)
    #expect(editedRule.name == "Bank sender")
    #expect(editedRule.sender?.kind == .regex)
    #expect(editedRule.sender?.pattern == "^955\\d{2}$")
    #expect(editedRule.text == nil)
    #expect(editedRule.action == .allow)

    let reloadedAfterEdit = SiftAppModel(ruleDefaults: defaults)
    let persistedEditedRule = try #require(reloadedAfterEdit.rules.first)
    #expect(persistedEditedRule.name == "Bank sender")
    #expect(persistedEditedRule.sender?.pattern == "^955\\d{2}$")

    var toggledRule = persistedEditedRule
    toggledRule.enabled = false
    reloadedAfterEdit.rules[0] = toggledRule

    let reloadedAfterToggle = SiftAppModel(ruleDefaults: defaults)
    let persistedToggledRule = try #require(reloadedAfterToggle.rules.first)
    #expect(!persistedToggledRule.enabled)

    reloadedAfterToggle.deleteRule(id: addedRule.id)
    #expect(reloadedAfterToggle.rules.isEmpty)

    let reloadedAfterDelete = SiftAppModel(ruleDefaults: defaults)
    #expect(!reloadedAfterDelete.rules.contains { $0.id == addedRule.id })
}

@MainActor
@Test
func remoteSubmitFailureKeepsVisibleFeedback() async throws {
    let suiteName = "SiftTests.remoteFailure.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set(true, forKey: remoteSamplePrivacyConsentKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let model = SiftAppModel(
        remoteSampleClient: MockRemoteSampleClient(result: .failure(RemoteSampleClientError.noAccount)),
        appDefaults: defaults
    )
    model.submissionDestination = .remote
    model.submissionText = "您的验证码为 123456，请勿告知他人。"

    model.submitSample()
    try await waitUntil { model.isSubmittingSample == false && model.sampleSubmissionFeedback != nil }

    #expect(model.sampleSubmissionFeedback?.kind == .error)
    #expect(model.sampleSubmissionFeedback?.message == "请先在系统设置中登录 iCloud，再匿名共享样本")
    #expect(model.toastCenter.toast == nil)
    #expect(model.lastReceiptToken == nil)
}

@MainActor
@Test
func sanitizedPreviewUpdatesAfterDebounceAndClearsWithInput() async throws {
    let suiteName = "SiftTests.sanitizedPreview.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SiftAppModel(
        remoteSampleClient: MockRemoteSampleClient(result: .success("unused")),
        ledgerDefaults: defaults,
        categoryMappingDefaults: defaults
    )

    model.submissionText = "登录验证码为 482913，请勿告知他人。"
    #expect(model.sanitizedPreview.isEmpty)
    try await waitUntil { model.sanitizedPreview.contains("{{CODE}}") }
    #expect(model.shouldShowSanitizedPreview)

    model.submissionText = ""
    #expect(model.sanitizedPreview.isEmpty)
    #expect(!model.shouldShowSanitizedPreview)
}

@MainActor
@Test
func remoteSubmitSuccessStoresReceiptToken() async throws {
    let suiteName = "SiftTests.remoteSubmitCounter.\(UUID().uuidString)"
    let ledgerDefaults = try #require(UserDefaults(suiteName: suiteName))
    ledgerDefaults.set(true, forKey: remoteSamplePrivacyConsentKey)
    defer { ledgerDefaults.removePersistentDomain(forName: suiteName) }

    let client = MockRemoteSampleClient(result: .success("ck-record-123"))
    let model = SiftAppModel(
        remoteSampleClient: client,
        appDefaults: ledgerDefaults,
        ledgerDefaults: ledgerDefaults
    )
    model.submissionDestination = .remote
    model.selectedLabelID = "verification"
    model.submissionText = "您的验证码为 123456，请勿告知他人。"

    model.submitSample()
    try await waitUntil { model.lastReceiptToken != nil }

    #expect(model.lastReceiptToken == "ck-record-123")
    #expect(model.sampleSubmissionFeedback?.kind == .success)
    #expect(model.toastCenter.toast?.kind == .success)
    #expect(model.toastCenter.toast?.message == "匿名样本提交成功")
    #expect(model.submissionText.isEmpty)
    #expect(model.submittedSampleCount == 1)
    #expect(SubmissionLedger.count(defaults: ledgerDefaults) == 1)
    #expect(SubmissionHistoryCache.load(defaults: ledgerDefaults)?.submissions.count == 1)
    let submitted = await client.recorder.submissions
    #expect(submitted.count == 1)
    #expect(submitted.first?.labelID == "verification")
    #expect(submitted.first?.assessment?.predictedLabelID == "verification")
}

@MainActor
@Test
func similarCachedRemoteSubmissionIsNotSubmittedAgain() async throws {
    let suiteName = "SiftTests.remoteDuplicate.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    SubmissionHistoryCache.save(
        SubmissionHistoryCacheSnapshot(submissions: [
            RemoteSubmissionSummary(
                recordName: "existing",
                text: "游戏2.8版本更新完成，新增地图并修复组队掉线问题。",
                label: "transaction.message",
                submittedAt: .now
            )
        ], fullyLoaded: true),
        defaults: defaults
    )

    let client = MockRemoteSampleClient(result: .success("should-not-submit"))
    let model = SiftAppModel(remoteSampleClient: client, ledgerDefaults: defaults)
    model.submissionDestination = .remote
    model.selectedLabelID = "transaction.message"
    model.submissionText = "游戏2.9版本更新完成，新增地图并修复组队掉线问题。"

    model.submitSample()
    try await waitUntil { model.isSubmittingSample == false && model.sampleSubmissionFeedback != nil }

    #expect(model.isSubmittingSample == false)
    #expect(model.sampleSubmissionFeedback?.kind == .info)
    #expect(model.sampleSubmissionFeedback?.message == "您已提交过类似样本")
    #expect(await client.recorder.submissions.isEmpty)
}

@MainActor
@Test
func remoteSubmitDisagreementStillSubmitsWithHint() async throws {
    let suiteName = "SiftTests.remoteDisagreement.\(UUID().uuidString)"
    let ledgerDefaults = try #require(UserDefaults(suiteName: suiteName))
    ledgerDefaults.set(true, forKey: remoteSamplePrivacyConsentKey)
    defer { ledgerDefaults.removePersistentDomain(forName: suiteName) }

    let client = MockRemoteSampleClient(result: .success("ck-record-456"))
    let model = SiftAppModel(
        remoteSampleClient: client,
        appDefaults: ledgerDefaults,
        ledgerDefaults: ledgerDefaults
    )
    model.submissionDestination = .remote
    // The local model confidently reads this as a verification code, so a
    // pickup-code label is a high-confidence disagreement: the sample still
    // submits (corrections are valuable) with an informational hint.
    model.selectedLabelID = "life.pickup_code"
    model.submissionText = "您的验证码为 123456，请勿告知他人。"

    model.submitSample()
    try await waitUntil { model.lastReceiptToken != nil }

    #expect(model.lastReceiptToken == "ck-record-456")
    #expect(model.sampleSubmissionFeedback?.kind == .info)
    #expect(model.toastCenter.toast?.kind == .success)
    let submitted = await client.recorder.submissions
    #expect(submitted.count == 1)
    #expect(submitted.first?.labelID == "life.pickup_code")
    #expect(submitted.first?.assessment?.predictedLabelID != "life.pickup_code")
}

@MainActor
@Test
func remoteSubmitRequiresPrivacyConsent() throws {
    let suiteName = "SiftTests.remoteConsent.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let model = SiftAppModel(
        remoteSampleClient: MockRemoteSampleClient(result: .success("unused")),
        appDefaults: defaults
    )
    model.submissionDestination = .remote
    model.submissionText = "您的验证码为 123456，请勿告知他人。"

    model.submitSample()

    #expect(model.isSubmittingSample == false)
    #expect(model.sampleSubmissionFeedback?.kind == .error)
    #expect(model.sampleSubmissionFeedback?.message == "请先阅读并同意匿名提交隐私说明")
}

@MainActor
@Test
func submissionCategoryDefaultsToFirstLeafAndFollowsLocalModelUntilManuallyChanged() async throws {
    let suiteName = "SiftTests.submissionCategory.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SiftAppModel(
        remoteSampleClient: MockRemoteSampleClient(result: .success("unused")),
        ledgerDefaults: defaults,
        categoryMappingDefaults: defaults
    )
    let firstLabelID = try #require(SiftTaxonomy.leaves.first?.id)

    #expect(model.selectedLabelID == firstLabelID)

    model.submissionText = "您的验证码为 123456，请勿告知他人。"
    try await waitUntil { model.selectedLabelID == "verification" }

    model.selectSubmissionLabel("finance.bank")
    model.submissionText = "您的取件码为 9527，请及时取件。"
    try await Task.sleep(for: .milliseconds(400))
    #expect(model.selectedLabelID == "finance.bank")

    model.submissionText = ""
    #expect(model.selectedLabelID == firstLabelID)
}

@MainActor
@Test
func remoteReceiptIsSessionOnlyAndClearsOnForeground() {
    let model = SiftAppModel()
    model.lastReceiptToken = "receipt-test-token"
    model.clearTransientReceipt()

    #expect(model.lastReceiptToken == nil)

    let reloaded = SiftAppModel()
    #expect(reloaded.lastReceiptToken == nil)
}

@MainActor
@Test
func remoteSubmissionFinishingAfterForegroundResetDoesNotRestoreReceipt() async throws {
    let suiteName = "SiftTests.remoteReceipt.inFlight.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set(true, forKey: remoteSamplePrivacyConsentKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let gate = DelayedSubmissionGate()
    let model = SiftAppModel(
        remoteSampleClient: DelayedRemoteSampleClient(gate: gate),
        appDefaults: defaults,
        ledgerDefaults: defaults
    )
    model.submissionDestination = .remote
    model.selectedLabelID = "verification"
    model.submissionText = "您的验证码为 123456，请勿告知他人。"

    model.submitSample()
    try await waitUntilSubmissionStarts(gate)
    model.clearTransientReceipt()
    await gate.release()
    try await waitUntil { !model.isSubmittingSample }

    #expect(model.lastReceiptToken == nil)
    #expect(model.submissionHistory.first?.recordName == "delayed-receipt")
    #expect(model.toastCenter.toast?.kind == .success)
}

@MainActor
@Test
func testPreviewAppliesCustomRulesBeforeModel() async throws {
    let suiteName = "SiftTests.rules.preview.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let model = SiftAppModel(
        remoteSampleClient: MockRemoteSampleClient(result: .success("unused")),
        ruleDefaults: defaults
    )
    model.ruleDraftName = "Marker rule"
    model.ruleDraftLocation = .body
    model.ruleDraftPatternKind = .substring
    model.ruleDraftPattern = "SIFTRULEMARKER"
    model.ruleDraftAction = .allow
    #expect(model.addCustomRuleFromDraft())

    model.testBody = "随便一句话 SIFTRULEMARKER 结尾"
    model.classifyCurrentDraft()
    try await waitUntil { model.lastDecision != nil }

    #expect(model.lastDecision?.source == .rule)
    #expect(model.lastDecision?.labelID == "transaction.message")
    #expect(model.lastDecision?.systemAction == SystemAction.none)
    #expect(model.lastDecision?.confidence == 1)
}

// MARK: - Test doubles

struct SubmittedSample: Sendable {
    let text: String
    let labelID: String
    let modelVersion: String?
    let assessment: LocalAssessment?
}

actor SubmissionRecorder {
    var submissions: [SubmittedSample] = []
    var deletedTokens: [String] = []
    var historyFetchCount: Int = 0

    func record(_ sample: SubmittedSample) {
        submissions.append(sample)
    }

    func recordDeletion(_ token: String) {
        deletedTokens.append(token)
    }

    func recordHistoryFetch() {
        historyFetchCount += 1
    }
}

actor DelayedSubmissionGate {
    private(set) var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

struct DelayedRemoteSampleClient: RemoteSampleSubmitting {
    let gate: DelayedSubmissionGate

    func submit(
        sanitizedText: String,
        labelID: String,
        modelVersion: String?,
        assessment: LocalAssessment?
    ) async throws -> RemoteSampleReceipt {
        await gate.waitForRelease()
        return RemoteSampleReceipt(accepted: true, receiptToken: "delayed-receipt")
    }

    func delete(receiptToken: String) async throws -> Bool { true }
    func fetchMySubmissions() async throws -> [RemoteSubmissionSummary] { [] }
    func fetchMySubmissions(before createdAtMillis: Int64?, limit: Int) async throws -> [RemoteSubmissionSummary] { [] }
    func eraseAllSubmissions() async throws -> Int { 0 }
}

struct MockRemoteSampleClient: RemoteSampleSubmitting {
    enum Result: Sendable {
        case success(String)
        case failure(any Error & Sendable)
    }

    let result: Result
    let recorder = SubmissionRecorder()

    func submit(
        sanitizedText: String,
        labelID: String,
        modelVersion: String?,
        assessment: LocalAssessment?
    ) async throws -> RemoteSampleReceipt {
        await recorder.record(SubmittedSample(
            text: sanitizedText,
            labelID: labelID,
            modelVersion: modelVersion,
            assessment: assessment
        ))
        switch result {
        case .success(let token):
            return RemoteSampleReceipt(accepted: true, receiptToken: token)
        case .failure(let error):
            throw error
        }
    }

    func delete(receiptToken: String) async throws -> Bool {
        await recorder.recordDeletion(receiptToken)
        switch result {
        case .success:
            return true
        case .failure(let error):
            throw error
        }
    }

    var seededHistory: [RemoteSubmissionSummary] = []

    func fetchMySubmissions() async throws -> [RemoteSubmissionSummary] {
        await recorder.recordHistoryFetch()
        switch result {
        case .success:
            return seededHistory
        case .failure(let error):
            throw error
        }
    }

    func fetchMySubmissions(before createdAtMillis: Int64?, limit: Int) async throws -> [RemoteSubmissionSummary] {
        await recorder.recordHistoryFetch()
        switch result {
        case .success:
            let sorted = seededHistory.sorted { ($0.createdAtMillis ?? 0) > ($1.createdAtMillis ?? 0) }
            let filtered = createdAtMillis.map { anchor in
                sorted.filter { ($0.createdAtMillis ?? 0) < anchor }
            } ?? sorted
            return Array(filtered.prefix(limit))
        case .failure(let error):
            throw error
        }
    }

    func eraseAllSubmissions() async throws -> Int {
        switch result {
        case .success:
            return 0
        case .failure(let error):
            throw error
        }
    }
}

struct SelectiveDeletionClient: RemoteSampleSubmitting {
    func submit(
        sanitizedText: String,
        labelID: String,
        modelVersion: String?,
        assessment: LocalAssessment?
    ) async throws -> RemoteSampleReceipt {
        throw RemoteSampleClientError.noAccount
    }

    func delete(receiptToken: String) async throws -> Bool {
        if receiptToken == "fails" {
            throw RemoteSampleClientError.noAccount
        }
        return true
    }

    func fetchMySubmissions() async throws -> [RemoteSubmissionSummary] {
        []
    }

    func fetchMySubmissions(before createdAtMillis: Int64?, limit: Int) async throws -> [RemoteSubmissionSummary] {
        []
    }

    func eraseAllSubmissions() async throws -> Int {
        0
    }
}

/// Polls the main actor until `condition` holds, failing after ~2 seconds.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for condition")
}

private func waitUntilSubmissionStarts(_ gate: DelayedSubmissionGate) async throws {
    for _ in 0..<200 {
        if await gate.hasStarted {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for delayed submission")
}
#endif
