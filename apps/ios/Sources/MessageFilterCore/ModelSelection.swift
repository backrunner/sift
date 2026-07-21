import Foundation

/// The two classifier families the app can run.
///
/// - `classic`: Create ML text classifier plus the on-device personalization
///   adapter. Supports local fine-tuning.
/// - `transformer`: multilingual transformer classifier exported to Core ML.
///   Trained offline for multilingual coverage; **not** fine-tunable on
///   device, so all personalization UI is hidden while it is active.
public enum ModelVariant: String, CaseIterable, Codable, Sendable, Identifiable {
    case classic
    case transformer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .classic:
            return String(localized: "经典模型")
        case .transformer:
            return "Transformer"
        }
    }

    public var subtitle: String {
        switch self {
        case .classic:
            return String(localized: "轻量算法 · 支持本地微调")
        case .transformer:
            return String(localized: "多语言 · 不支持本地微调")
        }
    }

    public var symbol: String {
        switch self {
        case .classic:
            return "gearshape.2"
        case .transformer:
            return "brain.filled.head.profile"
        }
    }

    /// Whether local sample collection + on-device personalization applies.
    public var supportsLocalPersonalization: Bool {
        self == .classic
    }
}

/// Persists the selected model variant in the shared app-group defaults so
/// the main app and the message-filter extension agree on which model runs.
public enum ModelSelectionStore {
    public static let appGroupIdentifier = "group.com.alkinum.sift"
    static let selectionKey = "Sift.selectedModelVariant"

    public static func load(defaults: UserDefaults? = nil) -> ModelVariant {
        FilterConfigurationSnapshotStore.load(defaults: defaults).selectedVariant
    }

    static func loadLegacy(defaults: UserDefaults? = nil) -> ModelVariant {
        let store = defaults ?? sharedDefaults()
        guard
            let raw = store.string(forKey: selectionKey),
            let variant = ModelVariant(rawValue: raw)
        else {
            return .classic
        }
        return variant
    }

    public static func save(
        _ variant: ModelVariant,
        defaults: UserDefaults? = nil,
        artifactIdentity: ModelArtifactIdentity? = nil
    ) {
        let store = defaults ?? sharedDefaults()
        store.set(variant.rawValue, forKey: selectionKey)
        FilterConfigurationSnapshotStore.update(
            defaults: store,
            selectedVariant: variant,
            modelArtifactIdentity: artifactIdentity ?? FilterConfigurationSnapshotStore.identity(for: variant)
        )
    }

    /// Falls back to standard defaults when the app group is not provisioned
    /// (unit tests, or debug builds without the capability).
    static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}

/// Persists custom rules in the shared app-group defaults so the app and the
/// message-filter extension always see the same rule set.
public enum SharedRuleStore {
    static let rulesKey = "Sift.customRules"

    public static func save(_ rules: [CustomRule], defaults: UserDefaults? = nil) {
        guard let data = try? JSONEncoder().encode(rules) else {
            return
        }
        let store = defaults ?? ModelSelectionStore.sharedDefaults()
        store.set(data, forKey: rulesKey)
        FilterConfigurationSnapshotStore.update(defaults: store, rules: rules)
    }

    public static func load(defaults: UserDefaults? = nil) -> [CustomRule] {
        FilterConfigurationSnapshotStore.load(defaults: defaults).rules
    }

    static func loadLegacy(defaults: UserDefaults? = nil) -> [CustomRule] {
        let store = defaults ?? ModelSelectionStore.sharedDefaults()
        guard let data = store.data(forKey: rulesKey) else {
            return []
        }
        return (try? JSONDecoder().decode([CustomRule].self, from: data)) ?? []
    }
}

/// User-selected destination for a taxonomy leaf. These overrides are applied
/// after classification, so they work for both model decisions and custom
/// rules without changing taxonomy IDs or retraining the model.
public enum CategoryMappingTarget: String, CaseIterable, Codable, Sendable, Identifiable {
    case promotion
    case junk

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .promotion:
            return String(localized: "推广信息")
        case .junk:
            return String(localized: "垃圾信息")
        }
    }

    public var symbol: String {
        switch self {
        case .promotion:
            return "megaphone.fill"
        case .junk:
            return "trash.fill"
        }
    }

    public var systemAction: SystemAction {
        switch self {
        case .promotion:
            return .promotion
        case .junk:
            return .junk
        }
    }
}

public enum CategoryMappingPolicy {
    public static let targetLabelIDs: Set<String> = ["promotion", "spam"]

    public static func isEligibleSource(labelID: String) -> Bool {
        SiftTaxonomy.leaf(id: labelID) != nil && !targetLabelIDs.contains(labelID)
    }
}

/// Persists per-category action overrides in App Group defaults so the app
/// and the IdentityLookup extension make the same final routing decision.
public enum SharedCategoryMappingStore {
    static let mappingsKey = "Sift.categoryMappings.v1"

    public static func save(_ mappings: [String: CategoryMappingTarget], defaults: UserDefaults? = nil) {
        let validMappings = mappings.filter { CategoryMappingPolicy.isEligibleSource(labelID: $0.key) }
        guard let data = try? JSONEncoder().encode(validMappings) else {
            return
        }
        let store = defaults ?? ModelSelectionStore.sharedDefaults()
        store.set(data, forKey: mappingsKey)
        FilterConfigurationSnapshotStore.update(defaults: store, categoryMappings: validMappings)
    }

    public static func load(defaults: UserDefaults? = nil) -> [String: CategoryMappingTarget] {
        FilterConfigurationSnapshotStore.load(defaults: defaults).categoryMappings
    }

    static func loadLegacy(defaults: UserDefaults? = nil) -> [String: CategoryMappingTarget] {
        let store = defaults ?? ModelSelectionStore.sharedDefaults()
        guard
            let data = store.data(forKey: mappingsKey),
            let mappings = try? JSONDecoder().decode([String: CategoryMappingTarget].self, from: data)
        else {
            return [:]
        }
        return mappings.filter { CategoryMappingPolicy.isEligibleSource(labelID: $0.key) }
    }
}

/// A local, sanitized copy of the user's most recently loaded submission
/// history. It avoids a CloudKit round-trip every time the history screen is
/// opened and is updated immediately when the user submits or erases data.
public struct SubmissionHistoryCacheSnapshot: Codable, Hashable, Sendable {
    public let submissions: [RemoteSubmissionSummary]
    public let fullyLoaded: Bool
    public let updatedAt: Date

    public init(
        submissions: [RemoteSubmissionSummary],
        fullyLoaded: Bool,
        updatedAt: Date = .now
    ) {
        self.submissions = submissions
        self.fullyLoaded = fullyLoaded
        self.updatedAt = updatedAt
    }
}

public enum SubmissionHistoryCache {
    static let cacheKey = "Sift.submissionHistoryCache.v1"

    public static func load(defaults: UserDefaults? = nil) -> SubmissionHistoryCacheSnapshot? {
        let store = defaults ?? ModelSelectionStore.sharedDefaults()
        guard let data = store.data(forKey: cacheKey) else {
            return nil
        }
        return try? JSONDecoder().decode(SubmissionHistoryCacheSnapshot.self, from: data)
    }

    public static func save(_ snapshot: SubmissionHistoryCacheSnapshot, defaults: UserDefaults? = nil) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        (defaults ?? ModelSelectionStore.sharedDefaults()).set(data, forKey: cacheKey)
    }

    public static func remove(defaults: UserDefaults? = nil) {
        (defaults ?? ModelSelectionStore.sharedDefaults()).removeObject(forKey: cacheKey)
    }
}


/// Local counter of successfully contributed samples, kept in the shared
/// app-group defaults so the dashboard can show "已贡献 N 条" without a
/// network round-trip. The CloudKit history list stays the source of truth.
public enum SubmissionLedger {
    static let countKey = "Sift.submittedSampleCount"

    public static func count(defaults: UserDefaults? = nil) -> Int {
        (defaults ?? ModelSelectionStore.sharedDefaults()).integer(forKey: countKey)
    }

    public static func increment(defaults: UserDefaults? = nil) {
        let store = defaults ?? ModelSelectionStore.sharedDefaults()
        store.set(count(defaults: store) + 1, forKey: countKey)
    }

    public static func decrement(defaults: UserDefaults? = nil) {
        let store = defaults ?? ModelSelectionStore.sharedDefaults()
        store.set(max(count(defaults: store) - 1, 0), forKey: countKey)
    }

    public static func set(_ count: Int, defaults: UserDefaults? = nil) {
        (defaults ?? ModelSelectionStore.sharedDefaults()).set(max(count, 0), forKey: countKey)
    }

    public static func reset(defaults: UserDefaults? = nil) {
        set(0, defaults: defaults)
    }
}
