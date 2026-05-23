import Foundation
import CryptoKit

public struct ModelManifest: Codable, Hashable, Sendable {
    public let version: String
    public let trainedAt: String
    public let taxonomyHash: String
    public let featureHasherVersion: String
    public let sha256: String
    public let modelURL: String?
    public let signature: String?
    public let publicKeyID: String?

    public init(
        version: String,
        trainedAt: String,
        taxonomyHash: String,
        featureHasherVersion: String,
        sha256: String,
        modelURL: String?,
        signature: String? = nil,
        publicKeyID: String? = nil
    ) {
        self.version = version
        self.trainedAt = trainedAt
        self.taxonomyHash = taxonomyHash
        self.featureHasherVersion = featureHasherVersion
        self.sha256 = sha256
        self.modelURL = modelURL
        self.signature = signature
        self.publicKeyID = publicKeyID
    }

    public func canonicalPayload() -> Data {
        let payload: [String: String?] = [
            "version": version,
            "trainedAt": trainedAt,
            "taxonomyHash": taxonomyHash,
            "featureHasherVersion": featureHasherVersion,
            "sha256": sha256,
            "modelURL": modelURL,
            "publicKeyID": publicKeyID
        ]
        let sorted = payload.sorted { $0.key < $1.key }
        let json = sorted.reduce(into: [String: String]()) { result, pair in
            if let value = pair.value {
                result[pair.key] = value
            }
        }
        return (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
    }
}

public enum ManifestVerificationError: Error, Hashable {
    case checksumMismatch
    case missingSignature
    case invalidSignature
    case invalidKey
}

public struct ModelManifestVerifier {
    public init() {}

    public func checksum(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    public func verifyChecksum(of data: Data, manifest: ModelManifest) throws {
        guard checksum(for: data) == manifest.sha256 else {
            throw ManifestVerificationError.checksumMismatch
        }
    }

    public func verifySignature(of manifest: ModelManifest, publicKeyBase64: String) throws {
        guard let signatureBase64 = manifest.signature else {
            throw ManifestVerificationError.missingSignature
        }
        guard
            let keyData = Data(base64Encoded: publicKeyBase64),
            let signatureData = Data(base64Encoded: signatureBase64)
        else {
            throw ManifestVerificationError.invalidKey
        }

        let publicKey = try P256.Signing.PublicKey(rawRepresentation: keyData)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        guard publicKey.isValidSignature(signature, for: manifest.canonicalPayload()) else {
            throw ManifestVerificationError.invalidSignature
        }
    }
}

public enum BundledModelManifest {
    public static func load(
        resourceName: String = "SiftSMSClassifier",
        bundles: [Bundle] = [.main]
    ) -> ModelManifest? {
        let decoder = JSONDecoder()
        for bundle in bundles {
            guard let url = bundle.url(forResource: "\(resourceName).manifest", withExtension: "json") else {
                continue
            }

            guard
                let data = try? Data(contentsOf: url),
                let manifest = try? decoder.decode(ModelManifest.self, from: data)
            else {
                continue
            }

            return manifest
        }
        return nil
    }
}
