import Foundation

#if canImport(CloudKit)
import CloudKit
#endif

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Receipt describing one accepted anonymous sample submission. The token is
/// the CloudKit record name; keeping it lets the user delete that record later.
public struct RemoteSampleReceipt: Codable, Hashable, Sendable {
    public let accepted: Bool
    public let receiptToken: String?

    public init(accepted: Bool, receiptToken: String?) {
        self.accepted = accepted
        self.receiptToken = receiptToken
    }
}

/// Anything that can receive anonymous sanitized samples. Production uses
/// CloudKit; tests inject an in-memory double.
public protocol RemoteSampleSubmitting: Sendable {
    func accountStatus() async -> RemoteSampleAccountStatus

    func submit(
        sanitizedText: String,
        labelID: String,
        modelVersion: String?,
        assessment: LocalAssessment?
    ) async throws -> RemoteSampleReceipt

    func delete(receiptToken: String) async throws -> Bool

    /// GDPR right-of-access support: fetches every sample the current user
    /// contributed (CloudKit creator match).
    func fetchMySubmissions() async throws -> [RemoteSubmissionSummary]

    /// One page of the user's submissions, newest first. `before` is the
    /// `createdAtMillis` of the last row already shown (nil for page one).
    func fetchMySubmissions(before createdAtMillis: Int64?, limit: Int) async throws -> [RemoteSubmissionSummary]

    /// GDPR right-of-erasure support: deletes every sample the current user
    /// contributed. Returns the number of deleted records.
    func eraseAllSubmissions() async throws -> Int
}

public extension RemoteSampleSubmitting {
    func accountStatus() async -> RemoteSampleAccountStatus {
        .available
    }
}

public enum RemoteSampleAccountStatus: Hashable, Sendable {
    case checking
    case available
    case noAccount
    case restricted
    case unknown
    case unavailable
}

/// A user-owned submission as returned by the access/erasure APIs.
public struct RemoteSubmissionSummary: Codable, Hashable, Sendable, Identifiable {
    public let recordName: String
    public let text: String
    public let label: String
    public let submittedAt: Date?
    /// Client timestamp (epoch ms) used as the keyset-pagination anchor.
    public let createdAtMillis: Int64?

    public var id: String { recordName }

    public init(recordName: String, text: String, label: String, submittedAt: Date?, createdAtMillis: Int64? = nil) {
        self.recordName = recordName
        self.text = text
        self.label = label
        self.submittedAt = submittedAt
        self.createdAtMillis = createdAtMillis
    }
}

/// The on-device model's own read of the submitted sample. Stored alongside
/// the sample so training-side curation can weigh user/model disagreement —
/// submissions are never blocked on it (corrections are the most valuable
/// rows), but persistent low-agreement contributors are down-weighted by the
/// dataset quality gate.
public struct LocalAssessment: Hashable, Sendable {
    public let predictedLabelID: String
    public let confidence: Double

    public init(predictedLabelID: String, confidence: Double) {
        self.predictedLabelID = predictedLabelID
        self.confidence = confidence
    }
}

public enum RemoteSampleClientError: Error, Hashable {
    /// CloudKit is not available in this build environment.
    case cloudKitUnavailable
    /// No iCloud account is signed in on this device.
    case noAccount
    /// The device's iCloud account cannot write (parental controls / MDM).
    case accountRestricted
    /// iCloud account state could not be determined.
    case accountUnknown
}

/// Publishes sanitized samples into the app's CloudKit **public database**.
///
/// Records intentionally carry no account, device, or sender identity fields.
/// CloudKit itself associates the record with the creator so the "delete my
/// last submission" receipt keeps working, but the payload stays anonymous.
public struct CloudKitSampleClient: RemoteSampleSubmitting {
    public static let recordType = "SmsSample"
    public static let defaultContainerIdentifier = "iCloud.com.alkinum.sift"
    public static let schemaVersion = 1

    public let containerIdentifier: String

    public init(containerIdentifier: String = CloudKitSampleClient.defaultContainerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    /// Resolves the container identifier from the app's Info.plist so debug
    /// builds can point at a development container.
    public static func configuredContainerIdentifier(bundle: Bundle = .main) -> String {
        let keys = ["SiftCloudKitContainerIdentifier", "SIFT_CLOUDKIT_CONTAINER"]
        for key in keys {
            if
                let value = bundle.object(forInfoDictionaryKey: key) as? String,
                !value.trimmingCharacters(in: .whitespaces).isEmpty
            {
                return value
            }
        }
        return defaultContainerIdentifier
    }

    public func accountStatus() async -> RemoteSampleAccountStatus {
        #if canImport(CloudKit) && os(iOS) && !targetEnvironment(simulator)
        let container = CKContainer(identifier: containerIdentifier)
        do {
            return Self.accountStatus(from: try await container.accountStatus())
        } catch {
            return .unknown
        }
        #else
        return .unavailable
        #endif
    }

    public func submit(
        sanitizedText: String,
        labelID: String,
        modelVersion: String?,
        assessment: LocalAssessment?
    ) async throws -> RemoteSampleReceipt {
        #if canImport(CloudKit) && os(iOS) && !targetEnvironment(simulator)
        let container = CKContainer(identifier: containerIdentifier)
        try await ensureWritableAccount(container: container)

        let record = CKRecord(recordType: Self.recordType)
        record["text"] = sanitizedText
        record["label"] = labelID
        if let leaf = SiftTaxonomy.leaf(id: labelID) {
            record["labelGroup"] = leaf.groupId
        }
        record["modelVersion"] = modelVersion
        record["schemaVersion"] = Self.schemaVersion
        record["source"] = "ios"
        // Coarse language/region tag (e.g. zh-CN) so exported corpora can be
        // balanced per language. Never a user identifier.
        record["locale"] = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        // Language of the sample TEXT itself (an English-locale user can
        // submit a Chinese SMS) — the device locale can't stand in for it.
        // Client-side detection beats training-side heuristics and feeds the
        // per-language dataset audits.
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sanitizedText)
        if let dominant = recognizer.dominantLanguage {
            record["textLanguage"] = dominant.rawValue
        }
        #endif
        record["createdAt"] = Int64(Date.now.timeIntervalSince1970 * 1000)
        if let assessment {
            record["predictedLabel"] = assessment.predictedLabelID
            record["predictedConfidence"] = assessment.confidence
            record["agreement"] = assessment.predictedLabelID == labelID ? 1 : 0
        }

        let saved = try await container.publicCloudDatabase.save(record)
        return RemoteSampleReceipt(accepted: true, receiptToken: saved.recordID.recordName)
        #else
        throw RemoteSampleClientError.cloudKitUnavailable
        #endif
    }

    public func delete(receiptToken: String) async throws -> Bool {
        #if canImport(CloudKit) && os(iOS) && !targetEnvironment(simulator)
        let container = CKContainer(identifier: containerIdentifier)
        do {
            _ = try await container.publicCloudDatabase.deleteRecord(withID: CKRecord.ID(recordName: receiptToken))
            return true
        } catch let error as CKError where error.code == .unknownItem {
            return false
        }
        #else
        throw RemoteSampleClientError.cloudKitUnavailable
        #endif
    }

    public func fetchMySubmissions() async throws -> [RemoteSubmissionSummary] {
        #if canImport(CloudKit) && os(iOS) && !targetEnvironment(simulator)
        let container = CKContainer(identifier: containerIdentifier)
        var summaries: [RemoteSubmissionSummary] = []
        for record in try await fetchMyRecords(container: container) {
            summaries.append(Self.summary(from: record))
        }
        return summaries
        #else
        throw RemoteSampleClientError.cloudKitUnavailable
        #endif
    }

    public func fetchMySubmissions(before createdAtMillis: Int64?, limit: Int) async throws -> [RemoteSubmissionSummary] {
        #if canImport(CloudKit) && os(iOS) && !targetEnvironment(simulator)
        let container = CKContainer(identifier: containerIdentifier)
        try await ensureWritableAccount(container: container)
        let userRecordID = try await container.userRecordID()

        let creator = CKRecord.Reference(recordID: userRecordID, action: .none)
        let predicate: NSPredicate
        if let createdAtMillis {
            predicate = NSPredicate(
                format: "creatorUserRecordID == %@ AND createdAt < %@",
                creator,
                NSNumber(value: createdAtMillis)
            )
        } else {
            predicate = NSPredicate(format: "creatorUserRecordID == %@", creator)
        }
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        let (results, _) = try await container.publicCloudDatabase.records(
            matching: query,
            resultsLimit: max(1, limit)
        )
        return results.compactMap { _, result in
            (try? result.get()).map(Self.summary(from:))
        }
        #else
        throw RemoteSampleClientError.cloudKitUnavailable
        #endif
    }

    #if canImport(CloudKit)
    private static func summary(from record: CKRecord) -> RemoteSubmissionSummary {
        RemoteSubmissionSummary(
            recordName: record.recordID.recordName,
            text: record["text"] as? String ?? "",
            label: record["label"] as? String ?? "",
            submittedAt: record.creationDate,
            createdAtMillis: (record["createdAt"] as? NSNumber)?.int64Value
        )
    }
    #endif

    public func eraseAllSubmissions() async throws -> Int {
        #if canImport(CloudKit) && os(iOS) && !targetEnvironment(simulator)
        let container = CKContainer(identifier: containerIdentifier)
        let recordIDs = try await fetchMyRecords(container: container).map(\.recordID)
        guard !recordIDs.isEmpty else {
            return 0
        }

        let database = container.publicCloudDatabase
        var deleted = 0
        // CloudKit caps modify operations; delete in conservative batches.
        for start in stride(from: 0, to: recordIDs.count, by: 100) {
            let batch = Array(recordIDs[start..<min(start + 100, recordIDs.count)])
            let (_, deletions) = try await database.modifyRecords(saving: [], deleting: batch)
            deleted += deletions.filter { (try? $0.value.get()) != nil }.count
        }
        return deleted
        #else
        throw RemoteSampleClientError.cloudKitUnavailable
        #endif
    }

    #if canImport(CloudKit)
    /// Every `SmsSample` the signed-in user created, paginated. CloudKit's
    /// creator association is what makes anonymous-yet-erasable possible: we
    /// never stored an identity, but the user can still reclaim their rows.
    private func fetchMyRecords(container: CKContainer) async throws -> [CKRecord] {
        try await ensureWritableAccount(container: container)
        let userRecordID = try await container.userRecordID()
        let predicate = NSPredicate(
            format: "creatorUserRecordID == %@",
            CKRecord.Reference(recordID: userRecordID, action: .none)
        )
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        let database = container.publicCloudDatabase

        var records: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let (results, nextCursor) = cursor == nil
                ? try await database.records(matching: query, resultsLimit: 200)
                : try await database.records(continuingMatchFrom: cursor!, resultsLimit: 200)
            for (_, result) in results {
                if let record = try? result.get() {
                    records.append(record)
                }
            }
            cursor = nextCursor
        } while cursor != nil
        return records
    }

    private func ensureWritableAccount(container: CKContainer) async throws {
        let status = try await container.accountStatus()
        switch Self.accountStatus(from: status) {
        case .available:
            return
        case .noAccount:
            throw RemoteSampleClientError.noAccount
        case .restricted:
            throw RemoteSampleClientError.accountRestricted
        case .unknown, .checking, .unavailable:
            throw RemoteSampleClientError.accountUnknown
        }
    }

    private static func accountStatus(from status: CKAccountStatus) -> RemoteSampleAccountStatus {
        switch status {
        case .available:
            return .available
        case .noAccount:
            return .noAccount
        case .restricted:
            return .restricted
        case .couldNotDetermine, .temporarilyUnavailable:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
    #endif
}
