import Foundation

public struct RemoteSampleRequest: Codable, Hashable, Sendable {
    public let text: String
    public let label: String
    public let source: String
    public let modelVersion: String?
    public let schemaVersion: Int

    public init(
        text: String,
        label: String,
        source: String = "remote",
        modelVersion: String?,
        schemaVersion: Int = 1
    ) {
        self.text = text
        self.label = label
        self.source = source
        self.modelVersion = modelVersion
        self.schemaVersion = schemaVersion
    }
}

public struct RemoteSampleReceipt: Codable, Hashable, Sendable {
    public let accepted: Bool
    public let receiptToken: String?
    public let sanitizedTextPreview: String?
    public let schemaVersion: Int?
    public let label: String?
    public let groupId: String?
    public let systemAction: String?
}

public enum RemoteSampleClientError: Error, Hashable {
    case invalidResponse
    case httpStatus(Int)
}

public struct RemoteSampleClient: Sendable {
    public let samplesEndpoint: URL
    public let timeoutSeconds: TimeInterval

    public init(samplesEndpoint: URL, timeoutSeconds: TimeInterval = 15) {
        self.samplesEndpoint = samplesEndpoint
        self.timeoutSeconds = timeoutSeconds
    }

    public func submit(
        sanitizedText: String,
        labelID: String,
        modelVersion: String?
    ) async throws -> RemoteSampleReceipt {
        var request = URLRequest(url: samplesEndpoint, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(
            RemoteSampleRequest(text: sanitizedText, label: labelID, modelVersion: modelVersion)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteSampleClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RemoteSampleClientError.httpStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(RemoteSampleReceipt.self, from: data)
    }

    public func delete(receiptToken: String) async throws -> Bool {
        let deleteURL = samplesEndpoint.appendingPathComponent(receiptToken)
        var request = URLRequest(url: deleteURL, timeoutInterval: timeoutSeconds)
        request.httpMethod = "DELETE"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteSampleClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RemoteSampleClientError.httpStatus(httpResponse.statusCode)
        }

        let payload = try JSONDecoder().decode([String: Bool].self, from: data)
        return payload["deleted"] ?? false
    }
}
