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
    case unsupportedDevice
    case transformerUnavailable
    case transformerTimedOut
}

public struct MessageFilterResult: Codable, Hashable, Sendable {
    public let decision: ClassificationDecision
    public let systemAction: SystemAction
    public let systemSubAction: SystemSubAction
    public let modelArtifactIdentity: ModelArtifactIdentity
    public let fallbackReason: MessageFilterFallbackReason

    public init(
        decision: ClassificationDecision,
        systemAction: SystemAction,
        systemSubAction: SystemSubAction,
        modelArtifactIdentity: ModelArtifactIdentity,
        fallbackReason: MessageFilterFallbackReason
    ) {
        self.decision = decision
        self.systemAction = systemAction
        self.systemSubAction = systemSubAction
        self.modelArtifactIdentity = modelArtifactIdentity
        self.fallbackReason = fallbackReason
    }
}

public enum MessageFilterRouting {
    public static func systemAction(for decision: ClassificationDecision) -> SystemAction {
        if decision.labelID == "carrier.promotion" {
            return .promotion
        }
        switch decision.systemAction {
        case .promotion:
            return .promotion
        case .junk:
            return .junk
        case .transaction:
            return decision.confidence >= 0.65 ? .transaction : .none
        case .none:
            return .none
        }
    }

    public static func systemSubAction(for decision: ClassificationDecision) -> SystemSubAction {
        switch systemAction(for: decision) {
        case .promotion:
            return ["carrier.promotion", "promotion"].contains(decision.labelID)
                ? .promotionalOffers : .promotionalOthers
        case .transaction:
            return transactionalSubAction(for: decision.labelID)
        case .junk, .none:
            return .none
        }
    }

    private static func transactionalSubAction(for labelID: String) -> SystemSubAction {
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

public protocol TransformerRuntimeLoading: Sendable {
    @concurrent
    func loadTransformer(identity: ModelArtifactIdentity) async -> (any MessageClassifier)?
}

public struct InstalledTransformerRuntimeLoader: TransformerRuntimeLoading {
    public init() {}

    @concurrent
    public func loadTransformer(identity: ModelArtifactIdentity) async -> (any MessageClassifier)? {
        guard
            identity.variant == .transformer,
            let installed = TransformerModelStore.installedModel(validateChecksums: false),
            installed.manifest.artifactIdentity == identity
        else {
            return nil
        }
        return TransformerClassifierLoader.downloaded()
    }
}

private actor TransformerRuntime {
    private struct Loading: Sendable {
        let id: UUID
        let identity: ModelArtifactIdentity
        let task: Task<(any MessageClassifier)?, Never>
    }

    private let loader: any TransformerRuntimeLoading
    private var identity: ModelArtifactIdentity?
    private var classifier: (any MessageClassifier)?
    private var loading: Loading?

    init(loader: any TransformerRuntimeLoading) {
        self.loader = loader
    }

    func classifier(for requestedIdentity: ModelArtifactIdentity) async -> (any MessageClassifier)? {
        if identity == requestedIdentity, let classifier {
            return classifier
        }
        let currentLoad: Loading
        if let loading, loading.identity == requestedIdentity {
            currentLoad = loading
        } else {
            classifier = nil
            identity = nil
            loading?.task.cancel()
            let loader = self.loader
            let task = Task.detached(priority: .userInitiated) {
                await loader.loadTransformer(identity: requestedIdentity)
            }
            let newLoad = Loading(id: UUID(), identity: requestedIdentity, task: task)
            loading = newLoad
            currentLoad = newLoad
        }
        let loaded = await currentLoad.task.value
        if identity == requestedIdentity, let classifier {
            return classifier
        }
        guard loading?.id == currentLoad.id else {
            return nil
        }
        self.loading = nil
        guard let loaded else {
            return nil
        }
        identity = requestedIdentity
        classifier = loaded
        return loaded
    }
}

public actor MessageFilterEngine {
    public static let defaultTransformerBudget: Duration = .milliseconds(500)

    private let classicClassifier: any MessageClassifier
    private let transformerRuntime: TransformerRuntime
    private let transformerDeviceSupport: TransformerDeviceSupport

    public init(
        classicClassifier: any MessageClassifier = AppleClassifierLoader.defaultClassifier(),
        transformerLoader: any TransformerRuntimeLoading = InstalledTransformerRuntimeLoader(),
        transformerDeviceSupport: TransformerDeviceSupport = .current()
    ) {
        self.classicClassifier = classicClassifier
        self.transformerRuntime = TransformerRuntime(loader: transformerLoader)
        self.transformerDeviceSupport = transformerDeviceSupport
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
                fallbackReason: .none
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

        guard case let .decision(transformerResult) = transformerOutcome else {
            return classifyWithClassic(
                request,
                configuration: configuration,
                fallbackReason: transformerOutcome == .timedOut ? .transformerTimedOut : .transformerUnavailable
            )
        }
        let mapped = transformerResult.applying(categoryMappings: configuration.categoryMappings)
        return result(decision: mapped, identity: configuration.modelArtifactIdentity, fallbackReason: .none)
    }

    private enum TransformerOutcome: Equatable, Sendable {
        case decision(ClassificationDecision)
        case unavailable
        case timedOut
    }

    private func raceTransformer(
        request: MessageFilterRequest,
        identity: ModelArtifactIdentity,
        budget: Duration
    ) async -> TransformerOutcome {
        let (stream, continuation) = AsyncStream<TransformerOutcome>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let runtime = transformerRuntime
        let inference = Task.detached(priority: .userInitiated) {
            guard let classifier = await runtime.classifier(for: identity) else {
                continuation.yield(.unavailable)
                return
            }
            guard !Task.isCancelled else {
                return
            }
            continuation.yield(.decision(classifier.classify(sender: request.sender, body: request.body)))
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
        let outcome = await iterator.next() ?? .unavailable
        continuation.finish()
        inference.cancel()
        timeout.cancel()
        return outcome
    }

    private func classifyWithClassic(
        _ request: MessageFilterRequest,
        configuration: FilterConfigurationSnapshot,
        fallbackReason: MessageFilterFallbackReason
    ) -> MessageFilterResult {
        let decision = ClassificationPipeline(classifier: classicClassifier)
            .classify(sender: request.sender, body: request.body, rules: [])
            .applying(categoryMappings: configuration.categoryMappings)
        return result(decision: decision, identity: .classic, fallbackReason: fallbackReason)
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
        fallbackReason: MessageFilterFallbackReason
    ) -> MessageFilterResult {
        MessageFilterResult(
            decision: decision,
            systemAction: MessageFilterRouting.systemAction(for: decision),
            systemSubAction: MessageFilterRouting.systemSubAction(for: decision),
            modelArtifactIdentity: identity,
            fallbackReason: fallbackReason
        )
    }
}
