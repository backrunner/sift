import Foundation

public enum SystemSubAction: String, Codable, Hashable, Sendable {
    case none
    case transactionalOthers
    case transactionalFinance
    case transactionalOrders
    case transactionalReminders
    case transactionalHealth
    case transactionalWeather
    case transactionalCarrier
    case transactionalRewards
    case transactionalPublicServices
    case promotionalOthers
    case promotionalOffers
    case promotionalCoupons
}

public struct ModelArtifactIdentity: Codable, Hashable, Sendable {
    public let variant: ModelVariant
    public let modelABI: String
    public let releaseSequence: Int
    public let sha256: String

    public init(variant: ModelVariant, modelABI: String, releaseSequence: Int, sha256: String) {
        self.variant = variant
        self.modelABI = modelABI
        self.releaseSequence = releaseSequence
        self.sha256 = sha256
    }

    public static let classic = ModelArtifactIdentity(
        variant: .classic,
        modelABI: "classic-v1",
        releaseSequence: 0,
        sha256: "bundled"
    )
}

public struct FilterConfigurationSnapshot: Codable, Hashable, Sendable {
    public let generation: UInt64
    public let selectedVariant: ModelVariant
    public let modelArtifactIdentity: ModelArtifactIdentity
    public let rules: [CustomRule]
    public let categoryMappings: [String: CategoryMappingTarget]

    public init(
        generation: UInt64,
        selectedVariant: ModelVariant,
        modelArtifactIdentity: ModelArtifactIdentity,
        rules: [CustomRule],
        categoryMappings: [String: CategoryMappingTarget]
    ) {
        self.generation = generation
        self.selectedVariant = selectedVariant
        self.modelArtifactIdentity = modelArtifactIdentity
        self.rules = rules
        self.categoryMappings = categoryMappings.filter {
            CategoryMappingPolicy.isEligibleSource(labelID: $0.key)
        }
    }

    public static let classicDefault = FilterConfigurationSnapshot(
        generation: 0,
        selectedVariant: .classic,
        modelArtifactIdentity: .classic,
        rules: [],
        categoryMappings: [:]
    )
}

/// A single App Group value replaces three independent reads in the extension's
/// hot path. UserDefaults publishes each encoded snapshot atomically.
public enum FilterConfigurationSnapshotStore {
    static let snapshotKey = "Sift.filterConfigurationSnapshot.v1"
    private static let lock = NSLock()

    public static func load(defaults: UserDefaults? = nil) -> FilterConfigurationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked(defaults: defaults)
    }

    private static func loadUnlocked(defaults: UserDefaults?) -> FilterConfigurationSnapshot {
        let store = defaults ?? ModelSelectionStore.sharedDefaults()
        if
            let data = store.data(forKey: snapshotKey),
            let snapshot = try? JSONDecoder().decode(FilterConfigurationSnapshot.self, from: data)
        {
            return snapshot
        }
        return legacySnapshot(defaults: store)
    }

    public static func save(_ snapshot: FilterConfigurationSnapshot, defaults: UserDefaults? = nil) {
        lock.lock()
        defer { lock.unlock() }
        saveUnlocked(snapshot, defaults: defaults)
    }

    private static func saveUnlocked(_ snapshot: FilterConfigurationSnapshot, defaults: UserDefaults?) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        (defaults ?? ModelSelectionStore.sharedDefaults()).set(data, forKey: snapshotKey)
    }

    static func update(
        defaults: UserDefaults?,
        selectedVariant: ModelVariant? = nil,
        modelArtifactIdentity: ModelArtifactIdentity? = nil,
        rules: [CustomRule]? = nil,
        categoryMappings: [String: CategoryMappingTarget]? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        let store = defaults ?? ModelSelectionStore.sharedDefaults()
        let current = loadUnlocked(defaults: store)
        let variant = selectedVariant ?? current.selectedVariant
        let identity = modelArtifactIdentity
            ?? (variant == current.modelArtifactIdentity.variant ? current.modelArtifactIdentity : identity(for: variant))
        saveUnlocked(
            FilterConfigurationSnapshot(
                generation: current.generation &+ 1,
                selectedVariant: variant,
                modelArtifactIdentity: identity,
                rules: rules ?? current.rules,
                categoryMappings: categoryMappings ?? current.categoryMappings
            ),
            defaults: store
        )
    }

    public static func refreshModelArtifactIdentity(defaults: UserDefaults? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let store = defaults ?? ModelSelectionStore.sharedDefaults()
        let current = loadUnlocked(defaults: store)
        saveUnlocked(
            FilterConfigurationSnapshot(
                generation: current.generation &+ 1,
                selectedVariant: current.selectedVariant,
                modelArtifactIdentity: identity(for: current.selectedVariant),
                rules: current.rules,
                categoryMappings: current.categoryMappings
            ),
            defaults: store
        )
    }

    public static func identity(for variant: ModelVariant) -> ModelArtifactIdentity {
        guard variant == .transformer, let manifest = TransformerClassifierLoader.manifest() else {
            return .classic
        }
        return manifest.artifactIdentity
    }

    private static func legacySnapshot(defaults: UserDefaults) -> FilterConfigurationSnapshot {
        let variant = ModelSelectionStore.loadLegacy(defaults: defaults)
        return FilterConfigurationSnapshot(
            generation: 0,
            selectedVariant: variant,
            modelArtifactIdentity: identity(for: variant),
            rules: SharedRuleStore.loadLegacy(defaults: defaults),
            categoryMappings: SharedCategoryMappingStore.loadLegacy(defaults: defaults)
        )
    }
}

public struct MessageFilterRequest: Hashable, Sendable {
    public let sender: String?
    public let body: String

    public init(sender: String?, body: String) {
        self.sender = sender
        self.body = body
    }
}

public enum MessageFilterFallbackReason: String, Codable, Hashable, Sendable {
    case none
    case configurationMismatch
    case unsupportedDevice
    case transformerUnavailable
    case transformerInferenceFailed
    case transformerTimedOut
    case handlerTimedOut
}

public enum MessageFilterExecutionPath: String, Codable, Hashable, Sendable {
    case rule
    case classic
    case signal
    case noDecision
}

public enum SignalModelAccessKind: String, Codable, Hashable, Sendable {
    case coldLoad
    case joinedInFlightLoad
    case cacheHit
}

public enum SignalModelFirstPredictionStrategy: String, Codable, Hashable, Sendable {
    /// The first Core ML prediction uses the actual SMS. A synthetic prediction
    /// would make a cold query wait for two back-to-back inferences.
    case realMessage
}

public struct SignalModelLoadPhaseMetrics: Codable, Hashable, Sendable {
    public let artifactResolutionMilliseconds: Int
    public let tokenizerMilliseconds: Int
    public let modelInitializationMilliseconds: Int
    public let firstPredictionStrategy: SignalModelFirstPredictionStrategy

    public init(
        artifactResolutionMilliseconds: Int = 0,
        tokenizerMilliseconds: Int = 0,
        modelInitializationMilliseconds: Int = 0,
        firstPredictionStrategy: SignalModelFirstPredictionStrategy = .realMessage
    ) {
        self.artifactResolutionMilliseconds = artifactResolutionMilliseconds
        self.tokenizerMilliseconds = tokenizerMilliseconds
        self.modelInitializationMilliseconds = modelInitializationMilliseconds
        self.firstPredictionStrategy = firstPredictionStrategy
    }
}

public struct SignalModelTimingMetrics: Codable, Hashable, Sendable {
    public let accessKind: SignalModelAccessKind
    public let totalLoadMilliseconds: Int
    public let queryWaitMilliseconds: Int
    public let inferenceMilliseconds: Int?
    public let loadPhases: SignalModelLoadPhaseMetrics?
    public let idleRetentionMilliseconds: Int

    public init(
        accessKind: SignalModelAccessKind,
        totalLoadMilliseconds: Int,
        queryWaitMilliseconds: Int,
        inferenceMilliseconds: Int? = nil,
        loadPhases: SignalModelLoadPhaseMetrics? = nil,
        idleRetentionMilliseconds: Int
    ) {
        self.accessKind = accessKind
        self.totalLoadMilliseconds = totalLoadMilliseconds
        self.queryWaitMilliseconds = queryWaitMilliseconds
        self.inferenceMilliseconds = inferenceMilliseconds
        self.loadPhases = loadPhases
        self.idleRetentionMilliseconds = idleRetentionMilliseconds
    }

    fileprivate func recordingInference(milliseconds: Int) -> SignalModelTimingMetrics {
        SignalModelTimingMetrics(
            accessKind: accessKind,
            totalLoadMilliseconds: totalLoadMilliseconds,
            queryWaitMilliseconds: queryWaitMilliseconds,
            inferenceMilliseconds: milliseconds,
            loadPhases: loadPhases,
            idleRetentionMilliseconds: idleRetentionMilliseconds
        )
    }
}

public enum SignalModelCacheReleaseReason: String, Codable, Hashable, Sendable {
    case idleTimeout
    case memoryPressure
    case attemptTimedOut
    case inferenceFailed
    case artifactChanged
}

public struct SignalModelCacheReleaseEvent: Codable, Hashable, Sendable {
    public let artifactIdentity: ModelArtifactIdentity
    public let reason: SignalModelCacheReleaseReason
    public let residencyMilliseconds: Int
    public let totalLoadMilliseconds: Int
    public let loadPhases: SignalModelLoadPhaseMetrics?

    public init(
        artifactIdentity: ModelArtifactIdentity,
        reason: SignalModelCacheReleaseReason,
        residencyMilliseconds: Int,
        totalLoadMilliseconds: Int = 0,
        loadPhases: SignalModelLoadPhaseMetrics? = nil
    ) {
        self.artifactIdentity = artifactIdentity
        self.reason = reason
        self.residencyMilliseconds = residencyMilliseconds
        self.totalLoadMilliseconds = totalLoadMilliseconds
        self.loadPhases = loadPhases
    }
}

public struct MessageFilterResult: Codable, Hashable, Sendable {
    public let decision: ClassificationDecision
    public let systemAction: SystemAction
    public let systemSubAction: SystemSubAction
    public let modelArtifactIdentity: ModelArtifactIdentity
    public let fallbackReason: MessageFilterFallbackReason
    public let executionPath: MessageFilterExecutionPath
    public let errorCode: String?
    public let signalTiming: SignalModelTimingMetrics?

    public init(
        decision: ClassificationDecision,
        systemAction: SystemAction,
        systemSubAction: SystemSubAction,
        modelArtifactIdentity: ModelArtifactIdentity,
        fallbackReason: MessageFilterFallbackReason,
        executionPath: MessageFilterExecutionPath,
        errorCode: String? = nil,
        signalTiming: SignalModelTimingMetrics? = nil
    ) {
        self.decision = decision
        self.systemAction = systemAction
        self.systemSubAction = systemSubAction
        self.modelArtifactIdentity = modelArtifactIdentity
        self.fallbackReason = fallbackReason
        self.executionPath = executionPath
        self.errorCode = errorCode
        self.signalTiming = signalTiming
    }
}

public enum MessageFilterRouting {
    public static func defaultMappingTarget(for leaf: LeafLabel) -> CategoryMappingTarget? {
        switch leaf.systemAction {
        case .junk:
            return .junk
        case .promotion:
            return ["carrier.promotion", "promotion"].contains(leaf.id)
                ? .promotionalOffers : .promotionalOthers
        case .transaction:
            return transactionalTarget(for: leaf.id)
        case .none:
            return nil
        }
    }

    public static func systemAction(for decision: ClassificationDecision) -> SystemAction {
        if let categoryMappingTarget = decision.categoryMappingTarget {
            return categoryMappingTarget.systemAction
        }
        if decision.labelID == "carrier.promotion" {
            return .promotion
        }
        switch decision.systemAction {
        case .promotion:
            return .promotion
        case .junk:
            return .junk
        case .transaction:
            return decision.confidence >= 0.60 ? .transaction : .none
        case .none:
            return .none
        }
    }

    public static func systemSubAction(for decision: ClassificationDecision) -> SystemSubAction {
        if let categoryMappingTarget = decision.categoryMappingTarget {
            return categoryMappingTarget.systemSubAction
        }
        switch systemAction(for: decision) {
        case .promotion:
            return ["carrier.promotion", "promotion"].contains(decision.labelID)
                ? .promotionalOffers : .promotionalOthers
        case .transaction:
            return transactionalTarget(for: decision.labelID).systemSubAction
        case .junk, .none:
            return .none
        }
    }

    private static func transactionalTarget(for labelID: String) -> CategoryMappingTarget {
        switch labelID {
        case let value where value.hasPrefix("finance."):
            return .transactionalFinance
        case "transaction.order", "life.takeaway", "life.express", "life.logistics", "life.pickup_code", "travel.ticketing":
            return .transactionalOrders
        case "work.meeting", "work.reminder", "work.training", "travel.transport":
            return .transactionalReminders
        case "life.medical":
            return .transactionalHealth
        case "life.weather":
            return .transactionalWeather
        case let value where value.hasPrefix("carrier."):
            return .transactionalCarrier
        case "transaction.points", "transaction.member":
            return .transactionalRewards
        case let value where value.hasPrefix("government."):
            return .transactionalPublicServices
        default:
            return .transactionalOthers
        }
    }
}

public struct TransformerRuntimeLoadResult: Sendable {
    public let classifier: (any MessageClassifier)?
    public let phaseMetrics: SignalModelLoadPhaseMetrics?

    public init(
        classifier: (any MessageClassifier)?,
        phaseMetrics: SignalModelLoadPhaseMetrics? = nil
    ) {
        self.classifier = classifier
        self.phaseMetrics = phaseMetrics
    }
}

func messageFilterMilliseconds(_ duration: Duration) -> Int {
    let milliseconds = duration / .milliseconds(1)
    guard milliseconds.isFinite, milliseconds > 0 else {
        return 0
    }
    return Int(min(milliseconds.rounded(), Double(Int.max)))
}

public protocol TransformerRuntimeLoading: Sendable {
    @concurrent
    func loadTransformer(identity: ModelArtifactIdentity) async -> TransformerRuntimeLoadResult
}

public struct InstalledTransformerRuntimeLoader: TransformerRuntimeLoading {
    public init() {}

    @concurrent
    public func loadTransformer(identity: ModelArtifactIdentity) async -> TransformerRuntimeLoadResult {
        let clock = ContinuousClock()
        let artifactStartedAt = clock.now
        guard identity.variant == .transformer else {
            return TransformerRuntimeLoadResult(classifier: nil)
        }
        guard
            let installed = TransformerClassifierLoader.installedModel(validateChecksums: false),
            installed.manifest.artifactIdentity == identity
        else {
            return TransformerRuntimeLoadResult(
                classifier: nil,
                phaseMetrics: SignalModelLoadPhaseMetrics(
                    artifactResolutionMilliseconds: messageFilterMilliseconds(
                        artifactStartedAt.duration(to: clock.now)
                    )
                )
            )
        }
        let artifactMilliseconds = messageFilterMilliseconds(artifactStartedAt.duration(to: clock.now))
        let attempt = TransformerClassifierLoader.loadDownloaded(installed: installed)
        return TransformerRuntimeLoadResult(
            classifier: attempt.classifier,
            phaseMetrics: SignalModelLoadPhaseMetrics(
                artifactResolutionMilliseconds: artifactMilliseconds,
                tokenizerMilliseconds: attempt.tokenizerMilliseconds,
                modelInitializationMilliseconds: attempt.modelInitializationMilliseconds
            )
        )
    }
}

private actor TransformerRuntime {
    private struct LoadCompletion: Sendable {
        let result: TransformerRuntimeLoadResult
        let totalLoadMilliseconds: Int
    }

    private struct Loading: Sendable {
        let id: UUID
        let identity: ModelArtifactIdentity
        let task: Task<LoadCompletion, Never>
    }

    private struct Cached: Sendable {
        let identity: ModelArtifactIdentity
        let classifier: any MessageClassifier
        let totalLoadMilliseconds: Int
        let phaseMetrics: SignalModelLoadPhaseMetrics?
        let loadedAt: ContinuousClock.Instant
    }

    private struct Resolution: Sendable {
        let classifier: (any MessageClassifier)?
        let accessKind: SignalModelAccessKind
        let totalLoadMilliseconds: Int
        let phaseMetrics: SignalModelLoadPhaseMetrics?
    }

    struct Access: Sendable {
        let classifier: (any MessageClassifier)?
        let timing: SignalModelTimingMetrics
    }

    private let loader: any TransformerRuntimeLoading
    private let idleRetention: Duration
    private let cacheReleaseHandler: (@Sendable (SignalModelCacheReleaseEvent) -> Void)?
    private var cached: Cached?
    private var loading: Loading?
    private var activeRequestCount = 0
    private var allowsIdleRetention = true
    private var pendingReleaseReason: SignalModelCacheReleaseReason?
    private var evictionGeneration: UInt64 = 0
    private var evictionTask: Task<Void, Never>?

    init(
        loader: any TransformerRuntimeLoading,
        idleRetention: Duration,
        cacheReleaseHandler: (@Sendable (SignalModelCacheReleaseEvent) -> Void)?
    ) {
        self.loader = loader
        self.idleRetention = idleRetention
        self.cacheReleaseHandler = cacheReleaseHandler
    }

    func acquire(for requestedIdentity: ModelArtifactIdentity) async -> Access {
        activeRequestCount += 1
        cancelIdleEviction()
        let clock = ContinuousClock()
        let startedAt = clock.now
        let resolution = await resolve(for: requestedIdentity)
        return Access(
            classifier: resolution.classifier,
            timing: SignalModelTimingMetrics(
                accessKind: resolution.accessKind,
                totalLoadMilliseconds: resolution.totalLoadMilliseconds,
                queryWaitMilliseconds: messageFilterMilliseconds(startedAt.duration(to: clock.now)),
                loadPhases: resolution.phaseMetrics,
                idleRetentionMilliseconds: messageFilterMilliseconds(idleRetention)
            )
        )
    }

    func finishAccess(releaseReason: SignalModelCacheReleaseReason? = nil) {
        activeRequestCount = max(0, activeRequestCount - 1)
        if let releaseReason {
            pendingReleaseReason = releaseReason
        }
        guard activeRequestCount == 0 else {
            return
        }
        if let pendingReleaseReason {
            self.pendingReleaseReason = nil
            releaseAll(reason: pendingReleaseReason)
        } else if allowsIdleRetention {
            scheduleIdleEviction()
        } else {
            releaseAll(reason: .memoryPressure)
        }
    }

    func requestCacheRelease(reason: SignalModelCacheReleaseReason) {
        pendingReleaseReason = reason
        guard activeRequestCount == 0 else {
            return
        }
        pendingReleaseReason = nil
        releaseAll(reason: reason)
    }

    func handleMemoryPressure() {
        allowsIdleRetention = false
        requestCacheRelease(reason: .memoryPressure)
    }

    private func resolve(for requestedIdentity: ModelArtifactIdentity) async -> Resolution {
        if let cached, cached.identity == requestedIdentity {
            return Resolution(
                classifier: cached.classifier,
                accessKind: .cacheHit,
                totalLoadMilliseconds: cached.totalLoadMilliseconds,
                phaseMetrics: cached.phaseMetrics
            )
        }
        if cached != nil {
            releaseCached(reason: .artifactChanged)
        }

        let currentLoad: Loading
        let accessKind: SignalModelAccessKind
        if let loading, loading.identity == requestedIdentity {
            currentLoad = loading
            accessKind = .joinedInFlightLoad
        } else {
            loading?.task.cancel()
            let loader = self.loader
            let clock = ContinuousClock()
            let task = Task.detached(priority: .userInitiated) {
                let startedAt = clock.now
                let result = await loader.loadTransformer(identity: requestedIdentity)
                return LoadCompletion(
                    result: result,
                    totalLoadMilliseconds: messageFilterMilliseconds(startedAt.duration(to: clock.now))
                )
            }
            let newLoad = Loading(id: UUID(), identity: requestedIdentity, task: task)
            loading = newLoad
            currentLoad = newLoad
            accessKind = .coldLoad
        }
        let completion = await currentLoad.task.value
        if let cached, cached.identity == requestedIdentity {
            return Resolution(
                classifier: cached.classifier,
                accessKind: accessKind,
                totalLoadMilliseconds: cached.totalLoadMilliseconds,
                phaseMetrics: cached.phaseMetrics
            )
        }
        guard loading?.id == currentLoad.id else {
            return Resolution(
                classifier: nil,
                accessKind: accessKind,
                totalLoadMilliseconds: completion.totalLoadMilliseconds,
                phaseMetrics: completion.result.phaseMetrics
            )
        }
        self.loading = nil
        guard let classifier = completion.result.classifier else {
            return Resolution(
                classifier: nil,
                accessKind: accessKind,
                totalLoadMilliseconds: completion.totalLoadMilliseconds,
                phaseMetrics: completion.result.phaseMetrics
            )
        }
        let cached = Cached(
            identity: requestedIdentity,
            classifier: classifier,
            totalLoadMilliseconds: completion.totalLoadMilliseconds,
            phaseMetrics: completion.result.phaseMetrics,
            loadedAt: ContinuousClock().now
        )
        self.cached = cached
        return Resolution(
            classifier: classifier,
            accessKind: accessKind,
            totalLoadMilliseconds: cached.totalLoadMilliseconds,
            phaseMetrics: cached.phaseMetrics
        )
    }

    private func scheduleIdleEviction() {
        guard cached != nil, activeRequestCount == 0, allowsIdleRetention else {
            return
        }
        cancelIdleEviction()
        evictionGeneration &+= 1
        let generation = evictionGeneration
        let idleRetention = self.idleRetention
        evictionTask = Task(name: "Sift Signal idle eviction") {
            do {
                try await Task.sleep(for: idleRetention)
            } catch {
                return
            }
            guard !Task.isCancelled, generation == evictionGeneration, activeRequestCount == 0 else {
                return
            }
            evictionTask = nil
            releaseCached(reason: .idleTimeout)
        }
    }

    private func cancelIdleEviction() {
        evictionTask?.cancel()
        evictionTask = nil
    }

    private func releaseAll(reason: SignalModelCacheReleaseReason) {
        cancelIdleEviction()
        loading?.task.cancel()
        loading = nil
        releaseCached(reason: reason)
    }

    private func releaseCached(reason: SignalModelCacheReleaseReason) {
        guard let cached else {
            return
        }
        self.cached = nil
        cacheReleaseHandler?(SignalModelCacheReleaseEvent(
            artifactIdentity: cached.identity,
            reason: reason,
            residencyMilliseconds: messageFilterMilliseconds(
                cached.loadedAt.duration(to: ContinuousClock().now)
            ),
            totalLoadMilliseconds: cached.totalLoadMilliseconds,
            loadPhases: cached.phaseMetrics
        ))
    }
}

public enum MessageFilterTimingPolicy {
    /// Apple's IdentityLookup API does not publish a numeric completion limit.
    /// Five seconds gives a cold Core ML process ten times the former budget.
    public static let signalAttemptBudget: Duration = .seconds(5)

    /// Last-resort completion guard with time left for Classic classification
    /// after Signal reaches its final attempt budget.
    public static let handlerWatchdog: Duration = .seconds(6)

    /// A short opportunity to reuse Signal for an SMS burst. App extensions
    /// are otherwise expected to be short-lived and every request must remain
    /// correct when the system launches a new process.
    public static let signalIdleRetention: Duration = .seconds(15)
}

public actor MessageFilterEngine {
    /// Compatibility alias for callers that customize the Signal race budget.
    public static let defaultTransformerBudget = MessageFilterTimingPolicy.signalAttemptBudget

    private var classicClassifier: (any MessageClassifier)?
    private let transformerRuntime: TransformerRuntime
    private let transformerDeviceSupport: TransformerDeviceSupport

    public init(
        classicClassifier: (any MessageClassifier)? = nil,
        transformerLoader: any TransformerRuntimeLoading = InstalledTransformerRuntimeLoader(),
        transformerDeviceSupport: TransformerDeviceSupport = .current(),
        transformerIdleRetention: Duration = MessageFilterTimingPolicy.signalIdleRetention,
        transformerCacheReleaseHandler: (@Sendable (SignalModelCacheReleaseEvent) -> Void)? = nil
    ) {
        self.classicClassifier = classicClassifier
        self.transformerRuntime = TransformerRuntime(
            loader: transformerLoader,
            idleRetention: transformerIdleRetention,
            cacheReleaseHandler: transformerCacheReleaseHandler
        )
        self.transformerDeviceSupport = transformerDeviceSupport
    }

    public func handleSignalMemoryPressure() async {
        await transformerRuntime.handleMemoryPressure()
    }

    public func classify(
        _ request: MessageFilterRequest,
        configuration: FilterConfigurationSnapshot,
        transformerBudget: Duration = MessageFilterEngine.defaultTransformerBudget
    ) async -> MessageFilterResult {
        if let ruleDecision = ruleDecision(for: request, rules: configuration.rules) {
            return result(
                decision: ruleDecision,
                identity: configuration.modelArtifactIdentity,
                fallbackReason: .none,
                executionPath: .rule
            )
        }

        guard configuration.selectedVariant == configuration.modelArtifactIdentity.variant else {
            return classifyWithClassic(
                request,
                configuration: configuration,
                fallbackReason: .configurationMismatch
            )
        }
        guard configuration.selectedVariant == .transformer else {
            return classifyWithClassic(request, configuration: configuration, fallbackReason: .none)
        }
        guard transformerDeviceSupport.isSupported else {
            return classifyWithClassic(
                request,
                configuration: configuration,
                fallbackReason: .unsupportedDevice
            )
        }

        let transformerOutcome = await raceTransformer(
            request: request,
            identity: configuration.modelArtifactIdentity,
            budget: transformerBudget
        )

        switch transformerOutcome {
        case let .decision(transformerResult, signalTiming):
            let calibrated = HeuristicClassifier.highPrecisionDecision(for: request.body)
                ?? transformerResult
            let mapped = calibrated.applying(categoryMappings: configuration.categoryMappings)
            return result(
                decision: mapped,
                identity: configuration.modelArtifactIdentity,
                fallbackReason: .none,
                executionPath: .signal,
                signalTiming: signalTiming
            )
        case let .unavailable(signalTiming):
            return classifyWithClassic(
                request,
                configuration: configuration,
                fallbackReason: .transformerUnavailable,
                signalTiming: signalTiming
            )
        case let .inferenceFailed(failure, signalTiming):
            return classifyWithClassic(
                request,
                configuration: configuration,
                fallbackReason: .transformerInferenceFailed,
                errorCode: "signal_\(failure.rawValue)",
                signalTiming: signalTiming
            )
        case .timedOut:
            return classifyWithClassic(
                request,
                configuration: configuration,
                fallbackReason: .transformerTimedOut
            )
        }
    }

    private enum TransformerOutcome: Sendable {
        case decision(ClassificationDecision, SignalModelTimingMetrics)
        case unavailable(SignalModelTimingMetrics?)
        case inferenceFailed(MessageClassifierInferenceFailure, SignalModelTimingMetrics)
        case timedOut
    }

    private func raceTransformer(
        request: MessageFilterRequest,
        identity: ModelArtifactIdentity,
        budget: Duration
    ) async -> TransformerOutcome {
        let (stream, continuation) = AsyncStream<TransformerOutcome>.makeStream(
            // This is a race, not a progress stream. Preserve whichever path
            // wins first even if the consumer resumes after the other yields.
            bufferingPolicy: .bufferingOldest(1)
        )
        let runtime = transformerRuntime
        let inference = Task.detached(priority: .userInitiated) {
            let access = await runtime.acquire(for: identity)
            guard let classifier = access.classifier else {
                let wasCancelled = Task.isCancelled
                await runtime.finishAccess(
                    releaseReason: wasCancelled ? .attemptTimedOut : nil
                )
                if !wasCancelled {
                    continuation.yield(.unavailable(access.timing))
                }
                return
            }
            guard !Task.isCancelled else {
                await runtime.finishAccess(releaseReason: .attemptTimedOut)
                return
            }
            let clock = ContinuousClock()
            let inferenceStartedAt = clock.now
            let outcome: TransformerOutcome
            let failureReleaseReason: SignalModelCacheReleaseReason?
            if let failureReportingClassifier = classifier as? any FailureReportingMessageClassifier {
                switch failureReportingClassifier.classificationResult(
                    sender: request.sender,
                    body: request.body
                ) {
                case let .success(decision):
                    let timing = access.timing.recordingInference(
                        milliseconds: messageFilterMilliseconds(inferenceStartedAt.duration(to: clock.now))
                    )
                    outcome = .decision(decision, timing)
                    failureReleaseReason = nil
                case let .failure(failure):
                    let timing = access.timing.recordingInference(
                        milliseconds: messageFilterMilliseconds(inferenceStartedAt.duration(to: clock.now))
                    )
                    outcome = .inferenceFailed(failure, timing)
                    failureReleaseReason = .inferenceFailed
                }
            } else {
                let decision = classifier.classify(sender: request.sender, body: request.body)
                let timing = access.timing.recordingInference(
                    milliseconds: messageFilterMilliseconds(inferenceStartedAt.duration(to: clock.now))
                )
                outcome = .decision(decision, timing)
                failureReleaseReason = nil
            }
            let wasCancelled = Task.isCancelled
            await runtime.finishAccess(
                releaseReason: wasCancelled ? .attemptTimedOut : failureReleaseReason
            )
            if !wasCancelled {
                continuation.yield(outcome)
            }
        }
        let timeout = Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(for: budget)
                continuation.yield(.timedOut)
            } catch {
                return
            }
        }
        var iterator = stream.makeAsyncIterator()
        let outcome = await iterator.next() ?? .unavailable(nil)
        continuation.finish()
        inference.cancel()
        timeout.cancel()
        if case .timedOut = outcome {
            await runtime.requestCacheRelease(reason: .attemptTimedOut)
        }
        return outcome
    }

    private func classifyWithClassic(
        _ request: MessageFilterRequest,
        configuration: FilterConfigurationSnapshot,
        fallbackReason: MessageFilterFallbackReason,
        errorCode: String? = nil,
        signalTiming: SignalModelTimingMetrics? = nil
    ) -> MessageFilterResult {
        let decision = ClassificationPipeline(classifier: resolvedClassicClassifier())
            .classify(sender: request.sender, body: request.body, rules: [])
            .applying(categoryMappings: configuration.categoryMappings)
        return result(
            decision: decision,
            identity: .classic,
            fallbackReason: fallbackReason,
            executionPath: .classic,
            errorCode: errorCode,
            signalTiming: signalTiming
        )
    }

    private func resolvedClassicClassifier() -> any MessageClassifier {
        if let classicClassifier {
            return classicClassifier
        }
        let loaded = AppleClassifierLoader.defaultClassifier()
        classicClassifier = loaded
        return loaded
    }

    private func ruleDecision(for request: MessageFilterRequest, rules: [CustomRule]) -> ClassificationDecision? {
        guard let match = RuleEngine().match(sender: request.sender, body: request.body, rules: rules) else {
            return nil
        }
        let action = match.rule.action
        let label = SiftTaxonomy.leaf(id: action.decisionLabelID) ?? SiftTaxonomy.leaves[0]
        return ClassificationDecision(
            labelID: label.id,
            labelTitle: label.title,
            groupID: label.groupId,
            groupTitle: label.groupTitle,
            confidence: 1,
            systemAction: action.systemAction,
            source: .rule
        )
    }

    private func result(
        decision: ClassificationDecision,
        identity: ModelArtifactIdentity,
        fallbackReason: MessageFilterFallbackReason,
        executionPath: MessageFilterExecutionPath,
        errorCode: String? = nil,
        signalTiming: SignalModelTimingMetrics? = nil
    ) -> MessageFilterResult {
        MessageFilterResult(
            decision: decision,
            systemAction: MessageFilterRouting.systemAction(for: decision),
            systemSubAction: MessageFilterRouting.systemSubAction(for: decision),
            modelArtifactIdentity: identity,
            fallbackReason: fallbackReason,
            executionPath: executionPath,
            errorCode: errorCode,
            signalTiming: signalTiming
        )
    }
}
