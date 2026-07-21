#if canImport(Testing)
import Foundation
@testable import MessageFilterCore
import Testing

private struct FixedClassifier: MessageClassifier {
    let labelID: String

    func classify(sender: String?, body: String) -> ClassificationDecision {
        let leaf = SiftTaxonomy.leaf(id: labelID) ?? SiftTaxonomy.leaves[0]
        return ClassificationDecision(
            labelID: leaf.id,
            labelTitle: leaf.title,
            groupID: leaf.groupId,
            groupTitle: leaf.groupTitle,
            confidence: 0.99,
            systemAction: leaf.systemAction,
            source: .model
        )
    }
}

private actor RuntimeLoadRecorder {
    private var identities: [ModelArtifactIdentity] = []

    func record(_ identity: ModelArtifactIdentity) {
        identities.append(identity)
    }

    func values() -> [ModelArtifactIdentity] {
        identities
    }
}

private final class SendableDefaultsBox: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

private struct RecordingRuntimeLoader: TransformerRuntimeLoading {
    let recorder: RuntimeLoadRecorder
    var delay: Duration = .zero
    var unavailable = false

    @concurrent
    func loadTransformer(identity: ModelArtifactIdentity) async -> (any MessageClassifier)? {
        await recorder.record(identity)
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        guard !unavailable else {
            return nil
        }
        return FixedClassifier(labelID: identity.sha256 == "release-2" ? "spam" : "promotion")
    }
}

private func transformerSnapshot(
    identity: ModelArtifactIdentity,
    rules: [CustomRule] = []
) -> FilterConfigurationSnapshot {
    FilterConfigurationSnapshot(
        generation: UInt64(identity.releaseSequence),
        selectedVariant: .transformer,
        modelArtifactIdentity: identity,
        rules: rules,
        categoryMappings: [:]
    )
}

@Test
func messageFilterRulesBypassTransformerLoading() async {
    let recorder = RuntimeLoadRecorder()
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: RecordingRuntimeLoader(recorder: recorder, unavailable: true)
    )
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 1,
        sha256: "release-1"
    )
    let rule = CustomRule(
        name: "Allow bank",
        sender: SenderMatcher(kind: .prefix, pattern: "955"),
        action: .allow
    )

    let result = await engine.classify(
        MessageFilterRequest(sender: "95588", body: "限时优惠"),
        configuration: transformerSnapshot(identity: identity, rules: [rule])
    )

    #expect(result.decision.source == .rule)
    #expect(result.systemAction == .none)
    #expect(result.fallbackReason == .none)
    #expect(await recorder.values().isEmpty)
}

@Test
func allowRuleCannotBeOverriddenByCategoryMapping() async {
    let recorder = RuntimeLoadRecorder()
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "spam"),
        transformerLoader: RecordingRuntimeLoader(recorder: recorder, unavailable: true)
    )
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 1,
        sha256: "release-1"
    )
    let rule = CustomRule(
        name: "Allow bank",
        sender: SenderMatcher(kind: .exact, pattern: "95588"),
        action: .allow
    )
    let configuration = FilterConfigurationSnapshot(
        generation: 1,
        selectedVariant: .transformer,
        modelArtifactIdentity: identity,
        rules: [rule],
        categoryMappings: ["transaction.message": .junk]
    )

    let result = await engine.classify(
        MessageFilterRequest(sender: "95588", body: "限时优惠"),
        configuration: configuration
    )

    #expect(result.decision.source == .rule)
    #expect(result.systemAction == .none)
    #expect(await recorder.values().isEmpty)
}

@Test
func messageFilterReloadsWhenTransformerArtifactIdentityChanges() async {
    let recorder = RuntimeLoadRecorder()
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: RecordingRuntimeLoader(recorder: recorder)
    )
    let first = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 1,
        sha256: "release-1"
    )
    let second = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 2,
        sha256: "release-2"
    )

    let firstResult = await engine.classify(
        MessageFilterRequest(sender: nil, body: "offer"),
        configuration: transformerSnapshot(identity: first)
    )
    let secondResult = await engine.classify(
        MessageFilterRequest(sender: nil, body: "scam"),
        configuration: transformerSnapshot(identity: second)
    )

    #expect(firstResult.systemAction == .promotion)
    #expect(firstResult.modelArtifactIdentity == first)
    #expect(secondResult.systemAction == .junk)
    #expect(secondResult.modelArtifactIdentity == second)
    #expect(await recorder.values() == [first, second])
}

@Test
func messageFilterFallsBackToClassicWhenTransformerExceedsBudget() async {
    let recorder = RuntimeLoadRecorder()
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: RecordingRuntimeLoader(recorder: recorder, delay: .milliseconds(150))
    )
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 1,
        sha256: "release-1"
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    let result = await engine.classify(
        MessageFilterRequest(sender: nil, body: "ordinary update"),
        configuration: transformerSnapshot(identity: identity),
        transformerBudget: .milliseconds(20)
    )

    #expect(startedAt.duration(to: clock.now) < .milliseconds(500))
    #expect(result.modelArtifactIdentity == .classic)
    #expect(result.fallbackReason == .transformerTimedOut)
    #expect(result.systemAction == .transaction)
}

@Test
func unsupportedDeviceNeverLoadsTransformerInMessageFilter() async {
    let recorder = RuntimeLoadRecorder()
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: RecordingRuntimeLoader(recorder: recorder),
        transformerDeviceSupport: TransformerDeviceSupport(
            status: .unsupported,
            reason: .belowMinimumNeuralEngine
        )
    )
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 1,
        sha256: "release-1"
    )

    let result = await engine.classify(
        MessageFilterRequest(sender: nil, body: "ordinary update"),
        configuration: transformerSnapshot(identity: identity)
    )

    #expect(result.modelArtifactIdentity == .classic)
    #expect(result.fallbackReason == .unsupportedDevice)
    #expect(result.systemAction == .transaction)
    #expect(await recorder.values().isEmpty)
}

@Test
func concurrentColdQueriesCoalesceOneTransformerLoad() async {
    let recorder = RuntimeLoadRecorder()
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: RecordingRuntimeLoader(recorder: recorder, delay: .milliseconds(50))
    )
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 1,
        sha256: "release-1"
    )
    let configuration = transformerSnapshot(identity: identity)

    async let first = engine.classify(
        MessageFilterRequest(sender: nil, body: "first"),
        configuration: configuration
    )
    async let second = engine.classify(
        MessageFilterRequest(sender: nil, body: "second"),
        configuration: configuration
    )
    let results = await [first, second]

    #expect(results.allSatisfy { $0.modelArtifactIdentity == identity })
    #expect(await recorder.values() == [identity])
}

@Test
func filterConfigurationSnapshotIsOneAtomicDefaultsValue() throws {
    let suiteName = "SiftTests.filterSnapshot.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 9,
        sha256: "sha"
    )
    let snapshot = FilterConfigurationSnapshot(
        generation: 4,
        selectedVariant: .transformer,
        modelArtifactIdentity: identity,
        rules: [],
        categoryMappings: ["finance.bank": .junk]
    )

    FilterConfigurationSnapshotStore.save(snapshot, defaults: defaults)

    #expect(FilterConfigurationSnapshotStore.load(defaults: defaults) == snapshot)
}

@Test
func concurrentSnapshotFieldUpdatesDoNotLoseIndependentChanges() async throws {
    let suiteName = "SiftTests.filterSnapshot.concurrent.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let defaultsBox = SendableDefaultsBox(defaults)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let rule = CustomRule(
        name: "Block sender",
        sender: SenderMatcher(kind: .exact, pattern: "10690000"),
        action: .block
    )

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            SharedRuleStore.save([rule], defaults: defaultsBox.value)
        }
        group.addTask {
            SharedCategoryMappingStore.save(["finance.bank": .junk], defaults: defaultsBox.value)
        }
    }

    let snapshot = FilterConfigurationSnapshotStore.load(defaults: defaults)
    #expect(snapshot.rules == [rule])
    #expect(snapshot.categoryMappings == ["finance.bank": .junk])
}
#endif
