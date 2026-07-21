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

public enum TransformerManifestCompatibility: Hashable, Sendable {
    case compatible
    case unsupportedSchema
    case unsupportedABI
    case appBuildTooOld
    case appBuildTooNew
    case operatingSystemTooOld
    case releaseRollback
}

public struct TransformerManifestVerifier: Sendable {
    public static let supportedSchemaVersion = 2
    public static let supportedModelABIs: Set<String> = ["sift-mmbert-v2", "sift-mmbert-v3"]

    private let publicKeys: [String: String]

    public init(publicKeys: [String: String]) {
        self.publicKeys = publicKeys
    }

    public func verifySignature(of channel: TransformerChannelManifestV2) throws {
        try verify(signature: channel.signature, keyID: channel.keyID, payload: channel.canonicalPayload())
    }

    public func verifySignature(of manifest: TransformerReleaseManifestV2) throws {
        guard let keyID = manifest.keyID else {
            throw ManifestVerificationError.invalidKey
        }
        try verify(signature: manifest.signature, keyID: keyID, payload: manifest.canonicalPayload())
    }

    public func compatibility(
        of channel: TransformerChannelManifestV2,
        appBuild: Int,
        operatingSystemVersion: OperatingSystemVersion,
        currentReleaseSequence: Int
    ) -> TransformerManifestCompatibility {
        guard channel.schemaVersion == Self.supportedSchemaVersion else {
            return .unsupportedSchema
        }
        guard Self.supportedModelABIs.contains(channel.modelABI) else {
            return .unsupportedABI
        }
        guard appBuild >= channel.minimumAppBuild else {
            return .appBuildTooOld
        }
        guard appBuild <= channel.maximumAppBuild else {
            return .appBuildTooNew
        }
        guard Self.isOperatingSystem(operatingSystemVersion, atLeast: channel.minimumOSVersion) else {
            return .operatingSystemTooOld
        }
        guard channel.releaseSequence >= currentReleaseSequence else {
            return .releaseRollback
        }
        return .compatible
    }

    public func validateRelease(
        _ manifest: TransformerReleaseManifestV2,
        for channel: TransformerChannelManifestV2
    ) throws {
        guard
            manifest.schemaVersion == channel.schemaVersion,
            manifest.releaseSequence == channel.releaseSequence,
            manifest.modelABI == channel.modelABI,
            manifest.minimumAppBuild == channel.minimumAppBuild,
            manifest.maximumAppBuild == channel.maximumAppBuild,
            manifest.minimumOSVersion == channel.minimumOSVersion,
            manifest.runtimeProfile.computeUnits == "all",
            manifest.runtimeProfile.transformerBudgetMilliseconds <= 500,
            [4, 8].contains(manifest.quantizationProfile.weightBits),
            manifest.quantizationProfile.activationBits == 8 || manifest.quantizationProfile.activationBits == 16
        else {
            throw TransformerManifestValidationError.channelReleaseMismatch
        }
    }

    public func checksum(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func verify(signature: String?, keyID: String, payload: Data) throws {
        guard let signature else {
            throw ManifestVerificationError.missingSignature
        }
        guard
            let publicKeyBase64 = publicKeys[keyID],
            let keyData = Data(base64Encoded: publicKeyBase64),
            let signatureData = Data(base64Encoded: signature)
        else {
            throw ManifestVerificationError.invalidKey
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        guard publicKey.isValidSignature(signatureData, for: payload) else {
            throw ManifestVerificationError.invalidSignature
        }
    }

    private static func isOperatingSystem(
        _ version: OperatingSystemVersion,
        atLeast minimumVersion: String
    ) -> Bool {
        let parts = minimumVersion.split(separator: ".").compactMap { Int($0) }
        let minimum = OperatingSystemVersion(
            majorVersion: parts.first ?? 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
        if version.majorVersion != minimum.majorVersion {
            return version.majorVersion > minimum.majorVersion
        }
        if version.minorVersion != minimum.minorVersion {
            return version.minorVersion > minimum.minorVersion
        }
        return version.patchVersion >= minimum.patchVersion
    }
}

public enum TransformerManifestValidationError: Error, Hashable, Sendable {
    case channelReleaseMismatch
    case releaseManifestChecksumMismatch
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
