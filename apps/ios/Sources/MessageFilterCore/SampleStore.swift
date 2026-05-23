import Foundation

public struct StoredSample: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let sender: String
    public let body: String
    public let labelID: String
    public let source: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        sender: String,
        body: String,
        labelID: String,
        source: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sender = sender
        self.body = body
        self.labelID = labelID
        self.source = source
    }
}

public actor LocalSampleStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        appGroupIdentifier: String? = nil,
        filename: String = "samples.ndjson"
    ) -> URL {
        let baseURL: URL
        if
            let appGroupIdentifier,
            let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        {
            baseURL = containerURL
        } else {
            baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }

        return baseURL
            .appendingPathComponent("Sift", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    public func append(_ sample: StoredSample) throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(sample)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        let endOffset = try handle.seekToEnd()
        if endOffset > 0 {
            try handle.write(contentsOf: Data([0x0A]))
        }
        try handle.write(contentsOf: data)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
        #endif
    }

    public func loadAll() throws -> [StoredSample] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            return []
        }

        return try data
            .split(separator: 0x0A)
            .compactMap { segment in
                guard !segment.isEmpty else { return nil }
                return try JSONDecoder().decode(StoredSample.self, from: Data(segment))
            }
    }

    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func ensureDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }
}
