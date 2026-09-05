#if canImport(Testing)
import Foundation
@testable import MessageFilterCore
import MessageFilterExtensionKit
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

private struct ResultReportingClassifier: FailureReportingMessageClassifier {
    let result: Result<ClassificationDecision, MessageClassifierInferenceFailure>

    func classify(sender: String?, body: String) -> ClassificationDecision {
        switch result {
        case let .success(decision):
            return decision
        case .failure:
            return ModelOutputContract.abstentionDecision(confidence: 0)
        }
    }

    func classificationResult(
        sender: String?,
        body: String
    ) -> Result<ClassificationDecision, MessageClassifierInferenceFailure> {
        result
    }
}

private struct StaticRuntimeLoader: TransformerRuntimeLoading {
    let classifier: any MessageClassifier

    @concurrent
    func loadTransformer(identity: ModelArtifactIdentity) async -> TransformerRuntimeLoadResult {
        TransformerRuntimeLoadResult(classifier: classifier)
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

private final class SignalCacheReleaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [SignalModelCacheReleaseEvent] = []

    func record(_ event: SignalModelCacheReleaseEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    func events() -> [SignalModelCacheReleaseEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

private final class ClassificationRecorder: MessageClassifier, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []
    private let classifier: FixedClassifier

    init(labelID: String) {
        self.classifier = FixedClassifier(labelID: labelID)
    }

    func classify(sender: String?, body: String) -> ClassificationDecision {
        lock.lock()
        bodies.append(body)
        lock.unlock()
        return classifier.classify(sender: sender, body: body)
    }

    func recordedBodies() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
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
    func loadTransformer(identity: ModelArtifactIdentity) async -> TransformerRuntimeLoadResult {
        await recorder.record(identity)
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        guard !unavailable else {
            return TransformerRuntimeLoadResult(classifier: nil)
        }
        return TransformerRuntimeLoadResult(
            classifier: FixedClassifier(labelID: identity.sha256 == "release-2" ? "spam" : "promotion")
        )
    }
}

private func transformerSnapshot(
    identity: ModelArtifactIdentity,
    rules: [CustomRule] = [],
    categoryMappings: [String: CategoryMappingTarget] = [:]
) -> FilterConfigurationSnapshot {
    FilterConfigurationSnapshot(
        generation: UInt64(identity.releaseSequence),
        selectedVariant: .transformer,
        modelArtifactIdentity: identity,
        rules: rules,
        categoryMappings: categoryMappings
    )
}

private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [MessageFilterStage] = []

    func record(_ stage: MessageFilterStage) { lock.withLock { stages.append(stage) } }
    func values() -> [MessageFilterStage] { lock.withLock { stages } }
}

private struct StageCheckingLoader: TransformerRuntimeLoading {
    let recorder: StageRecorder

    @concurrent
    func loadTransformer(identity: ModelArtifactIdentity) async -> TransformerRuntimeLoadResult {
        Issue.record("The engine dropped its stage observer")
        return TransformerRuntimeLoadResult(classifier: nil)
    }

    @concurrent
    func loadTransformer(
        identity: ModelArtifactIdentity,
        observer: MessageFilterStageObserver?
    ) async -> TransformerRuntimeLoadResult {
        #expect(recorder.values() == [.signalLoadStarted])
        observer?(.modelLoadStarted)
        observer?(.modelLoaded)
        return TransformerRuntimeLoadResult(classifier: FixedClassifier(labelID: "promotion"))
    }
}

@Test
func filterStagesPrecedeLoadingAndEndAfterDecision() async {
    let recorder = StageRecorder()
    let identity = ModelArtifactIdentity(variant: .transformer, modelABI: "test", releaseSequence: 1, sha256: "test")
    let engine = MessageFilterEngine(
        transformerLoader: StageCheckingLoader(recorder: recorder), transformerDeviceSupport: .supported
    )
    let result = await engine.classify(
        MessageFilterRequest(sender: nil, body: "sample"), configuration: transformerSnapshot(identity: identity),
        observer: { recorder.record($0) }
    )
    #expect(result.systemAction == .promotion)
    #expect(recorder.values() == [
        .signalLoadStarted, .modelLoadStarted, .modelLoaded, .signalReady,
        .signalInferenceStarted, .signalInferenceFinished, .decisionReady,
    ])
}

@Test
func unavailableSignalRecordsClassicFallbackBeforeCompletion() async {
    let recorder = StageRecorder()
    let identity = ModelArtifactIdentity(variant: .transformer, modelABI: "test", releaseSequence: 1, sha256: "test")
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "spam"),
        transformerLoader: RecordingRuntimeLoader(recorder: RuntimeLoadRecorder(), unavailable: true),
        transformerDeviceSupport: .supported
    )
    let result = await engine.classify(
        MessageFilterRequest(sender: nil, body: "sample"), configuration: transformerSnapshot(identity: identity),
        observer: { recorder.record($0) }
    )
    #expect(result.fallbackReason == .transformerUnavailable)
    #expect(result.systemAction == .junk)
    #expect(recorder.values() == [.signalLoadStarted, .classicStarted, .decisionReady])
}

@Test
func messageFilterTimingPolicyAllowsColdSignalStartup() {
    #expect(MessageFilterTimingPolicy.signalAttemptBudget == .seconds(5))
    #expect(MessageFilterEngine.defaultTransformerBudget == .seconds(5))
    #expect(MessageFilterTimingPolicy.handlerWatchdog == .seconds(6))
    #expect(MessageFilterTimingPolicy.signalIdleRetention == .seconds(15))
}

@Test
func modelCategoryMappingsReachEveryExtensionDestination() async {
    let recorder = RuntimeLoadRecorder()
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 1,
        sha256: "release-1"
    )
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "finance.bank"),
        transformerLoader: RecordingRuntimeLoader(recorder: recorder),
        transformerDeviceSupport: .supported
    )

    for target in CategoryMappingTarget.allCases {
        let classicResult = await engine.classify(
            MessageFilterRequest(sender: nil, body: "classic"),
            configuration: FilterConfigurationSnapshot(
                generation: 1,
                selectedVariant: .classic,
                modelArtifactIdentity: .classic,
                rules: [],
                categoryMappings: ["finance.bank": target]
            )
        )
        let transformerResult = await engine.classify(
            MessageFilterRequest(sender: nil, body: "signal"),
            configuration: transformerSnapshot(
                identity: identity,
                categoryMappings: ["promotion": target]
            )
        )
        let expectedRoute = MessageFilterExtensionRoute(
            action: target.systemAction,
            subAction: target.systemSubAction
        )

        #expect(classicResult.decision.categoryMappingTarget == target)
        #expect(transformerResult.decision.categoryMappingTarget == target)
        #expect(MessageFilterActionMapper.extensionRoute(for: classicResult) == expectedRoute)
        #expect(MessageFilterActionMapper.extensionRoute(for: transformerResult) == expectedRoute)
    }
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
func persistedSignalConfigurationExecutesTheSelectedSignalArtifact() async throws {
    let suiteName = "SiftTests.signalConfiguration.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let recorder = RuntimeLoadRecorder()
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 3,
        sha256: "signal-release-3"
    )
    ModelSelectionStore.save(
        .transformer,
        defaults: defaults,
        artifactIdentity: identity
    )
    let configuration = FilterConfigurationSnapshotStore.load(defaults: defaults)
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: RecordingRuntimeLoader(recorder: recorder),
        transformerDeviceSupport: .supported
    )

    let result = await engine.classify(
        MessageFilterRequest(sender: nil, body: "limited offer"),
        configuration: configuration
    )

    #expect(configuration.selectedVariant == .transformer)
    #expect(configuration.modelArtifactIdentity == identity)
    #expect(result.executionPath == .signal)
    #expect(result.modelArtifactIdentity == identity)
    #expect(result.fallbackReason == .none)
    #expect(await recorder.values() == [identity])
}

@Test
func inconsistentSignalConfigurationFallsBackWithoutLoadingSignal() async {
    let recorder = RuntimeLoadRecorder()
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: RecordingRuntimeLoader(recorder: recorder),
        transformerDeviceSupport: .supported
    )
    let configuration = FilterConfigurationSnapshot(
        generation: 8,
        selectedVariant: .transformer,
        modelArtifactIdentity: .classic,
        rules: [],
        categoryMappings: [:]
    )

    let result = await engine.classify(
        MessageFilterRequest(sender: nil, body: "ordinary update"),
        configuration: configuration
    )

    #expect(result.executionPath == .classic)
    #expect(result.modelArtifactIdentity == .classic)
    #expect(result.fallbackReason == .configurationMismatch)
    #expect(await recorder.values().isEmpty)
}

@Test
func inconsistentClassicConfigurationIsReportedWhileRunningClassic() async {
    let recorder = RuntimeLoadRecorder()
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: RecordingRuntimeLoader(recorder: recorder),
        transformerDeviceSupport: .supported
    )
    let signalIdentity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 3,
        sha256: "signal-release-3"
    )
    let configuration = FilterConfigurationSnapshot(
        generation: 9,
        selectedVariant: .classic,
        modelArtifactIdentity: signalIdentity,
        rules: [],
        categoryMappings: [:]
    )

    let result = await engine.classify(
        MessageFilterRequest(sender: nil, body: "ordinary update"),
        configuration: configuration
    )

    #expect(result.executionPath == .classic)
    #expect(result.modelArtifactIdentity == .classic)
    #expect(result.fallbackReason == .configurationMismatch)
    #expect(await recorder.values().isEmpty)
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
    #expect(result.executionPath == .classic)
    #expect(result.systemAction == .transaction)
}

@Test
func defaultBudgetDoesNotTreatTheFormer500MillisecondBoundaryAsFailure() async {
    let recorder = RuntimeLoadRecorder()
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: RecordingRuntimeLoader(recorder: recorder, delay: .milliseconds(650)),
        transformerDeviceSupport: .supported
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

    #expect(result.executionPath == .signal)
    #expect(result.modelArtifactIdentity == identity)
    #expect(result.fallbackReason == .none)
}

@Test
func explicitSignalInferenceFailureImmediatelyFallsBackToClassic() async {
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: StaticRuntimeLoader(classifier: ResultReportingClassifier(
            result: .failure(.predictionFailed)
        )),
        transformerDeviceSupport: .supported
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

    #expect(result.executionPath == .classic)
    #expect(result.modelArtifactIdentity == .classic)
    #expect(result.fallbackReason == .transformerInferenceFailed)
    #expect(result.errorCode == "signal_predictionFailed")
}

@Test
func signalAbstentionIsACompletedSignalResultInsteadOfClassicFallback() async {
    let abstention = ModelOutputContract.abstentionDecision(confidence: 0.41)
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: StaticRuntimeLoader(classifier: ResultReportingClassifier(
            result: .success(abstention)
        )),
        transformerDeviceSupport: .supported
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

    #expect(result.executionPath == .signal)
    #expect(result.modelArtifactIdentity == identity)
    #expect(result.fallbackReason == .none)
    #expect(result.decision.labelID == ModelOutputContract.abstainLabel)
    #expect(result.decision.source == .fallback)
}

@Test
func signalCalibrationPreservesSignalExecutionIdentity() async {
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: StaticRuntimeLoader(classifier: FixedClassifier(labelID: "spam")),
        transformerDeviceSupport: .supported
    )
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 3,
        sha256: "signal-calibration"
    )

    let result = await engine.classify(
        MessageFilterRequest(
            sender: nil,
            body: "You have a missed call from 010-8821 and the caller left no voicemail."
        ),
        configuration: transformerSnapshot(identity: identity)
    )

    #expect(result.decision.labelID == "carrier.call_reminder")
    #expect(result.systemAction == .transaction)
    #expect(result.executionPath == .signal)
    #expect(result.modelArtifactIdentity == identity)
    #expect(result.fallbackReason == .none)
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
func consecutiveSignalQueriesReportColdLoadThenCacheHit() async {
    let recorder = RuntimeLoadRecorder()
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: RecordingRuntimeLoader(recorder: recorder),
        transformerDeviceSupport: .supported
    )
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 1,
        sha256: "release-1"
    )
    let configuration = transformerSnapshot(identity: identity)

    let first = await engine.classify(
        MessageFilterRequest(sender: nil, body: "first"),
        configuration: configuration
    )
    let second = await engine.classify(
        MessageFilterRequest(sender: nil, body: "second"),
        configuration: configuration
    )

    #expect(first.signalTiming?.accessKind == .coldLoad)
    #expect(second.signalTiming?.accessKind == .cacheHit)
    #expect(first.signalTiming?.idleRetentionMilliseconds == 15_000)
    #expect(await recorder.values() == [identity])
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
    let accessKinds = Set(results.compactMap { $0.signalTiming?.accessKind })
    #expect(accessKinds == Set<SignalModelAccessKind>([.coldLoad, .joinedInFlightLoad]))
    #expect(await recorder.values() == [identity])
}

@Test
func memoryPressureReleasesSignalAndTheNextQueryColdLoadsAgain() async {
    let loadRecorder = RuntimeLoadRecorder()
    let releaseRecorder = SignalCacheReleaseRecorder()
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: RecordingRuntimeLoader(recorder: loadRecorder),
        transformerDeviceSupport: .supported,
        transformerCacheReleaseHandler: { releaseRecorder.record($0) }
    )
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 1,
        sha256: "release-1"
    )
    let configuration = transformerSnapshot(identity: identity)

    let first = await engine.classify(
        MessageFilterRequest(sender: nil, body: "first"),
        configuration: configuration
    )
    await engine.handleSignalMemoryPressure()
    let second = await engine.classify(
        MessageFilterRequest(sender: nil, body: "second"),
        configuration: configuration
    )

    #expect(first.signalTiming?.accessKind == .coldLoad)
    #expect(second.signalTiming?.accessKind == .coldLoad)
    #expect(await loadRecorder.values() == [identity, identity])
    #expect(releaseRecorder.events().contains { $0.reason == .memoryPressure })
}

@Test(.timeLimit(.minutes(1)))
func aLoadCompletingAfterTimeoutIsReleasedAndReportsItsLoadDuration() async throws {
    let loadRecorder = RuntimeLoadRecorder()
    let (releaseEvents, releaseContinuation) = AsyncStream<SignalModelCacheReleaseEvent>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: RecordingRuntimeLoader(recorder: loadRecorder, delay: .milliseconds(50)),
        transformerDeviceSupport: .supported,
        transformerCacheReleaseHandler: { releaseContinuation.yield($0) }
    )
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 1,
        sha256: "release-1"
    )
    var iterator = releaseEvents.makeAsyncIterator()

    let result = await engine.classify(
        MessageFilterRequest(sender: nil, body: "slow cold start"),
        configuration: transformerSnapshot(identity: identity),
        transformerBudget: .milliseconds(1)
    )
    let releaseEvent = try #require(await iterator.next())
    releaseContinuation.finish()

    #expect(result.executionPath == .classic)
    #expect(result.fallbackReason == .transformerTimedOut)
    #expect(releaseEvent.reason == .attemptTimedOut)
    #expect(releaseEvent.artifactIdentity == identity)
    #expect(releaseEvent.totalLoadMilliseconds > 0)
    #expect(await loadRecorder.values() == [identity])
}

@Test(.timeLimit(.minutes(1)))
func idleRetentionReleasesSignalAndEmitsLifecycleEvent() async throws {
    let loadRecorder = RuntimeLoadRecorder()
    let (releaseEvents, releaseContinuation) = AsyncStream<SignalModelCacheReleaseEvent>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: RecordingRuntimeLoader(recorder: loadRecorder),
        transformerDeviceSupport: .supported,
        transformerIdleRetention: .milliseconds(1),
        transformerCacheReleaseHandler: { releaseContinuation.yield($0) }
    )
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 1,
        sha256: "release-1"
    )
    let configuration = transformerSnapshot(identity: identity)
    var iterator = releaseEvents.makeAsyncIterator()

    let first = await engine.classify(
        MessageFilterRequest(sender: nil, body: "first"),
        configuration: configuration
    )
    let releaseEvent = try #require(await iterator.next())
    let second = await engine.classify(
        MessageFilterRequest(sender: nil, body: "second"),
        configuration: configuration
    )
    releaseContinuation.finish()

    #expect(first.signalTiming?.accessKind == .coldLoad)
    #expect(releaseEvent.artifactIdentity == identity)
    #expect(releaseEvent.reason == .idleTimeout)
    #expect(second.signalTiming?.accessKind == .coldLoad)
    #expect(await loadRecorder.values() == [identity, identity])
}

@Test
func firstSignalQueryRunsExactlyOnePredictionForTheRealMessage() async {
    let classifier = ClassificationRecorder(labelID: "promotion")
    let engine = MessageFilterEngine(
        classicClassifier: FixedClassifier(labelID: "transaction.message"),
        transformerLoader: StaticRuntimeLoader(classifier: classifier),
        transformerDeviceSupport: .supported
    )
    let identity = ModelArtifactIdentity(
        variant: .transformer,
        modelABI: "sift-signal-v1",
        releaseSequence: 1,
        sha256: "release-1"
    )
    let configuration = transformerSnapshot(identity: identity)

    let result = await engine.classify(
        MessageFilterRequest(sender: nil, body: "first real message"),
        configuration: configuration
    )

    #expect(result.executionPath == .signal)
    #expect(classifier.recordedBodies() == ["first real message"])
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
