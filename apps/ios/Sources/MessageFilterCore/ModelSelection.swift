import Foundation

/// The two classifier families the app can run.
///
/// - `classic`: Create ML text classifier plus the on-device personalization
///   adapter. Supports local fine-tuning.
/// - `transformer`: SetFit-style sentence-transformer exported to Core ML.
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
        let store = defaults ?? sharedDefaults()
        guard
            let raw = store.string(forKey: selectionKey),
            let variant = ModelVariant(rawValue: raw)
        else {
            return .classic
        }
        return variant
    }

    public static func save(_ variant: ModelVariant, defaults: UserDefaults? = nil) {
        (defaults ?? sharedDefaults()).set(variant.rawValue, forKey: selectionKey)
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
        (defaults ?? ModelSelectionStore.sharedDefaults()).set(data, forKey: rulesKey)
    }

    public static func load(defaults: UserDefaults? = nil) -> [CustomRule] {
        let store = defaults ?? ModelSelectionStore.sharedDefaults()
        guard let data = store.data(forKey: rulesKey) else {
            return []
        }
        return (try? JSONDecoder().decode([CustomRule].self, from: data)) ?? []
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

    public static func reset(defaults: UserDefaults? = nil) {
        (defaults ?? ModelSelectionStore.sharedDefaults()).set(0, forKey: countKey)
    }
}
