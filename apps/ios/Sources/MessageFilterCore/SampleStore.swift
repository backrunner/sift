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

public enum SubmissionSimilarity {
    /// Conservative local-only comparison for duplicate submissions. Short
    /// texts require an exact canonical match; longer texts may differ only
    /// slightly after numbers and formatting are normalized.
    public static func isSimilar(_ lhs: String, _ rhs: String) -> Bool {
        let left = canonicalText(lhs)
        let right = canonicalText(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        guard min(left.count, right.count) >= 12 else { return false }

        let leftShingles = shingles(left, width: 3)
        let rightShingles = shingles(right, width: 3)
        guard !leftShingles.isEmpty, !rightShingles.isEmpty else { return false }
        let overlap = leftShingles.intersection(rightShingles).count
        let dice = (2 * Double(overlap)) / Double(leftShingles.count + rightShingles.count)
        return dice >= 0.92
    }

    private static func canonicalText(_ text: String) -> String {
        let normalized = text.precomposedStringWithCanonicalMapping.lowercased()
        var result = String.UnicodeScalarView()
        var isInsideNumber = false

        for scalar in normalized.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                if !isInsideNumber {
                    result.append("#")
                }
                isInsideNumber = true
            } else if CharacterSet.letters.contains(scalar) {
                result.append(scalar)
                isInsideNumber = false
            }
        }
        return String(result)
    }

    private static func shingles(_ text: String, width: Int) -> Set<String> {
        let characters = Array(text)
        guard characters.count >= width else { return [] }
        return Set((0...(characters.count - width)).map { index in
            String(characters[index..<(index + width)])
        })
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

    @discardableResult
    public func appendIfUnique(_ sample: StoredSample) throws -> Bool {
        let existing = try loadAll()
        guard !existing.contains(where: {
            $0.labelID == sample.labelID && SubmissionSimilarity.isSimilar($0.body, sample.body)
        }) else {
            return false
        }
        try append(sample)
        return true
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
