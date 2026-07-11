import Foundation

#if canImport(CloudKit)
import CloudKit
#endif

/// One local day of filtering counters. Counts only — never message content.
public struct DailyFilterStats: Codable, Hashable, Sendable, Identifiable {
    public var day: String
    public var total: Int
    public var junk: Int
    public var promotion: Int
    public var transaction: Int
    public var byGroup: [String: Int]

    public var id: String { day }

    public init(
        day: String,
        total: Int = 0,
        junk: Int = 0,
        promotion: Int = 0,
        transaction: Int = 0,
        byGroup: [String: Int] = [:]
    ) {
        self.day = day
        self.total = total
        self.junk = junk
        self.promotion = promotion
        self.transaction = transaction
        self.byGroup = byGroup
    }

    /// Per-counter max merge: statistics may be written from several devices
    /// (or a reinstall) and counters only ever grow, so max is the safe union.
    public func merged(with other: DailyFilterStats) -> DailyFilterStats {
        var merged = DailyFilterStats(
            day: day,
            total: max(total, other.total),
            junk: max(junk, other.junk),
            promotion: max(promotion, other.promotion),
            transaction: max(transaction, other.transaction),
            byGroup: byGroup
        )
        for (group, count) in other.byGroup {
            merged.byGroup[group] = max(merged.byGroup[group] ?? 0, count)
        }
        return merged
    }
}

/// Daily counting buckets in the shared app-group defaults. The
/// message-filter extension increments on every classified message; the app
/// reads for the dashboard and mirrors to the user's CloudKit private
/// database as a backup. `UserDefaults` is documented thread-safe, hence
/// `@unchecked`.
public struct FilterStatisticsStore: @unchecked Sendable {
    static let storageKey = "Sift.filterStats.v1"
    static let lifetimeTotalsKey = "Sift.filterStats.lifetimeTotals.v1"
    static let firstDashboardDayKey = "Sift.filterStats.firstDashboardDay.v1"
    static let retentionDays = 90

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? ModelSelectionStore.sharedDefaults()
    }

    public func record(decision: ClassificationDecision, date: Date = .now) {
        var buckets = loadAll()
        var totals = loadLifetimeTotals(fallback: buckets)
        let key = Self.dayKey(for: date)
        var stats = buckets[key] ?? DailyFilterStats(day: key)
        stats.total += 1
        totals.total += 1
        switch decision.systemAction {
        case .junk:
            stats.junk += 1
            totals.junk += 1
        case .promotion:
            stats.promotion += 1
            totals.promotion += 1
        case .transaction, .none:
            stats.transaction += 1
            totals.transaction += 1
        }
        stats.byGroup[decision.groupID, default: 0] += 1
        totals.byGroup[decision.groupID, default: 0] += 1
        buckets[key] = stats
        persist(prune(buckets, now: date))
        persistLifetimeTotals(totals)
    }

    public func stats(for date: Date = .now) -> DailyFilterStats {
        loadAll()[Self.dayKey(for: date)] ?? DailyFilterStats(day: Self.dayKey(for: date))
    }

    /// The most recent `days` buckets ending today, oldest first; missing
    /// days are zero-filled so charts stay aligned.
    public func recent(days: Int, endingAt date: Date = .now) -> [DailyFilterStats] {
        let buckets = loadAll()
        let calendar = Calendar.current
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else {
                return nil
            }
            let key = Self.dayKey(for: day)
            return buckets[key] ?? DailyFilterStats(day: key)
        }
    }

    public func replace(day: DailyFilterStats) {
        var buckets = loadAll()
        let previous = buckets[day.day] ?? DailyFilterStats(day: day.day)
        var totals = loadLifetimeTotals(fallback: buckets)
        totals.total = max(totals.total + day.total - previous.total, 0)
        totals.junk = max(totals.junk + day.junk - previous.junk, 0)
        totals.promotion = max(totals.promotion + day.promotion - previous.promotion, 0)
        totals.transaction = max(totals.transaction + day.transaction - previous.transaction, 0)
        for groupID in Set(previous.byGroup.keys).union(day.byGroup.keys) {
            let adjusted = (totals.byGroup[groupID] ?? 0)
                + (day.byGroup[groupID] ?? 0)
                - (previous.byGroup[groupID] ?? 0)
            totals.byGroup[groupID] = max(adjusted, 0)
        }
        buckets[day.day] = day
        persist(buckets)
        persistLifetimeTotals(totals)
    }

    public func allDays() -> [DailyFilterStats] {
        loadAll().values.sorted { $0.day < $1.day }
    }

    /// Lifetime counters are stored separately from the 90-day chart buckets,
    /// so the dashboard total never decreases when old daily rows are pruned.
    public func totals() -> DailyFilterStats {
        let buckets = loadAll()
        return loadLifetimeTotals(fallback: buckets)
    }

    /// Records the first calendar day on which the dashboard was viewed and
    /// returns whether `date` is still that day. This keeps the onboarding
    /// hint to day one even when there are no messages to count yet.
    public func isFirstDashboardDay(on date: Date = .now) -> Bool {
        let day = Self.dayKey(for: date)
        if let firstDay = defaults.string(forKey: Self.firstDashboardDayKey) {
            return firstDay == day
        }
        defaults.set(day, forKey: Self.firstDashboardDayKey)
        return true
    }

    public func removeAll() {
        defaults.removeObject(forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.lifetimeTotalsKey)
    }

    // MARK: - Internals

    private func loadAll() -> [String: DailyFilterStats] {
        guard
            let data = defaults.data(forKey: Self.storageKey),
            let buckets = try? JSONDecoder().decode([String: DailyFilterStats].self, from: data)
        else {
            return [:]
        }
        return buckets
    }

    private func persist(_ buckets: [String: DailyFilterStats]) {
        if let data = try? JSONEncoder().encode(buckets) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func loadLifetimeTotals(fallback buckets: [String: DailyFilterStats]) -> DailyFilterStats {
        if
            let data = defaults.data(forKey: Self.lifetimeTotalsKey),
            let totals = try? JSONDecoder().decode(DailyFilterStats.self, from: data)
        {
            return totals
        }
        return buckets.values.reduce(into: DailyFilterStats(day: "total")) { result, day in
            result.total += day.total
            result.junk += day.junk
            result.promotion += day.promotion
            result.transaction += day.transaction
            for (group, count) in day.byGroup {
                result.byGroup[group, default: 0] += count
            }
        }
    }

    private func persistLifetimeTotals(_ totals: DailyFilterStats) {
        if let data = try? JSONEncoder().encode(totals) {
            defaults.set(data, forKey: Self.lifetimeTotalsKey)
        }
    }

    private func prune(_ buckets: [String: DailyFilterStats], now: Date) -> [String: DailyFilterStats] {
        guard buckets.count > Self.retentionDays else {
            return buckets
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: now)
            .map(Self.dayKey(for:)) ?? ""
        return buckets.filter { $0.key >= cutoff }
    }

    public static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Best-effort mirror of the daily counters into the user's CloudKit
/// **private database** — their own iCloud storage, invisible to us — so
/// statistics survive reinstalls and follow the user across devices.
/// Failures are silent by design: statistics backup must never surface
/// errors in the UI.
public struct CloudKitStatsSync: Sendable {
    public static let recordType = "FilterStats"

    public let containerIdentifier: String
    private let store: FilterStatisticsStore

    public init(
        containerIdentifier: String = CloudKitSampleClient.defaultContainerIdentifier,
        store: FilterStatisticsStore = FilterStatisticsStore()
    ) {
        self.containerIdentifier = containerIdentifier
        self.store = store
    }

    /// Pulls remote days, max-merges with local, then pushes days where the
    /// local counters are ahead. Returns the number of pushed days.
    @discardableResult
    public func sync() async -> Int {
        #if canImport(CloudKit) && os(iOS) && !targetEnvironment(simulator)
        let container = CKContainer(identifier: containerIdentifier)
        guard (try? await container.accountStatus()) == .available else {
            return 0
        }
        let database = container.privateCloudDatabase
        var pushed = 0

        for local in store.allDays() {
            let recordID = CKRecord.ID(recordName: "day-\(local.day)")
            do {
                let record = (try? await database.record(for: recordID)) ?? CKRecord(recordType: Self.recordType, recordID: recordID)
                let remote = Self.stats(from: record, day: local.day)
                let merged = local.merged(with: remote)
                if merged != local {
                    store.replace(day: merged)
                }
                if merged != remote {
                    Self.apply(merged, to: record)
                    _ = try await database.save(record)
                    pushed += 1
                }
            } catch {
                continue
            }
        }
        return pushed
        #else
        return 0
        #endif
    }

    /// Deletes every statistics backup record from the private database.
    /// Returns the number of deleted records.
    @discardableResult
    public func eraseBackup() async throws -> Int {
        #if canImport(CloudKit) && os(iOS) && !targetEnvironment(simulator)
        let container = CKContainer(identifier: containerIdentifier)
        let database = container.privateCloudDatabase
        var deleted = 0
        for local in store.allDays() {
            let recordID = CKRecord.ID(recordName: "day-\(local.day)")
            do {
                _ = try await database.deleteRecord(withID: recordID)
                deleted += 1
            } catch let error as CKError where error.code == .unknownItem {
                continue
            }
        }
        return deleted
        #else
        return 0
        #endif
    }

    #if canImport(CloudKit)
    private static func stats(from record: CKRecord, day: String) -> DailyFilterStats {
        var stats = DailyFilterStats(day: day)
        stats.total = record["total"] as? Int ?? 0
        stats.junk = record["junk"] as? Int ?? 0
        stats.promotion = record["promotion"] as? Int ?? 0
        stats.transaction = record["transaction"] as? Int ?? 0
        if
            let json = record["byGroup"] as? String,
            let data = json.data(using: .utf8),
            let byGroup = try? JSONDecoder().decode([String: Int].self, from: data)
        {
            stats.byGroup = byGroup
        }
        return stats
    }

    private static func apply(_ stats: DailyFilterStats, to record: CKRecord) {
        record["day"] = stats.day
        record["total"] = stats.total
        record["junk"] = stats.junk
        record["promotion"] = stats.promotion
        record["transaction"] = stats.transaction
        if let data = try? JSONEncoder().encode(stats.byGroup) {
            record["byGroup"] = String(decoding: data, as: UTF8.self)
        }
    }
    #endif
}
