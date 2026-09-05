import Foundation

#if canImport(CoreML)
import CoreML
#endif

/// A remotely hosted file that belongs to a transformer model release.
///
/// `.mlpackage` is a directory package, so remote distribution uses a manifest
/// with one entry per file inside the package instead of treating it as a
/// single downloadable file.
public struct TransformerRemoteArtifact: Codable, Hashable, Sendable {
    public let path: String
    public let sha256: String
    public let byteCount: Int64

    public init(path: String, sha256: String, byteCount: Int64) {
        self.path = path
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public struct TransformerRuntimeProfile: Codable, Hashable, Sendable {
    public static let supportedComputeUnits: Set<String> = [
        "all",
        "cpuOnly",
        "cpuAndGPU",
        "cpuAndNeuralEngine",
    ]

    public let computeUnits: String
    public let modelType: String
    /// Numeric precision used by the exported Core ML graph. Optional so
    /// legacy manifests retain their original canonical payload.
    public let computePrecision: String?
    /// Warm inference target used to qualify a release artifact. MessageFilter
    /// runtime fallback timing is controlled separately by MessageFilterTimingPolicy.
    public let inferenceBudgetMilliseconds: Int

    public init(
        computeUnits: String = "cpuOnly",
        modelType: String = "mlProgram",
        inferenceBudgetMilliseconds: Int = 500,
        computePrecision: String? = nil
    ) {
        self.computeUnits = computeUnits
        self.modelType = modelType
        self.computePrecision = computePrecision
        self.inferenceBudgetMilliseconds = inferenceBudgetMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case computeUnits
        case modelType
        case computePrecision
        case inferenceBudgetMilliseconds
        case transformerBudgetMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.computeUnits = try container.decodeIfPresent(String.self, forKey: .computeUnits) ?? "all"
        self.modelType = try container.decodeIfPresent(String.self, forKey: .modelType) ?? "mlProgram"
        self.computePrecision = try container.decodeIfPresent(String.self, forKey: .computePrecision)
        self.inferenceBudgetMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .inferenceBudgetMilliseconds
        ) ?? container.decodeIfPresent(
            Int.self,
            forKey: .transformerBudgetMilliseconds
        ) ?? 500
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(computeUnits, forKey: .computeUnits)
        try container.encode(modelType, forKey: .modelType)
        try container.encodeIfPresent(computePrecision, forKey: .computePrecision)
        try container.encode(inferenceBudgetMilliseconds, forKey: .inferenceBudgetMilliseconds)
    }
}

public struct TransformerQuantizationProfile: Codable, Hashable, Sendable {
    public let identifier: String
    public let weightBits: Int
    public let activationBits: Int
    public let method: String
    public let granularity: String
    public let blockSize: Int?

    public init(
        identifier: String,
        weightBits: Int,
        activationBits: Int,
        method: String,
        granularity: String,
        blockSize: Int? = nil
    ) {
        self.identifier = identifier
        self.weightBits = weightBits
        self.activationBits = activationBits
        self.method = method
        self.granularity = granularity
        self.blockSize = blockSize
    }

    public static let legacyInt8 = TransformerQuantizationProfile(
        identifier: "legacy-int8",
        weightBits: 8,
        activationBits: 16,
        method: "ptq",
        granularity: "per-channel"
    )
}

public struct TransformerValidationMetrics: Codable, Hashable, Sendable {
    public let fixedAccuracy: Double
    public let promotionAccuracy: Double
    public let fp16Agreement: Double
    public let languageAccuracy: [String: Double]

    public init(
        fixedAccuracy: Double,
        promotionAccuracy: Double,
        fp16Agreement: Double,
        languageAccuracy: [String: Double]
    ) {
        self.fixedAccuracy = fixedAccuracy
        self.promotionAccuracy = promotionAccuracy
        self.fp16Agreement = fp16Agreement
        self.languageAccuracy = languageAccuracy
    }

    public static let unavailable = TransformerValidationMetrics(
        fixedAccuracy: 0,
        promotionAccuracy: 0,
        fp16Agreement: 0,
        languageAccuracy: [:]
    )
}

/// Immutable provenance for a student produced by teacher-student distillation.
/// This is part of the signed release payload so a release cannot silently
/// change its teacher or distillation recipe after selection.
public struct TransformerDistillationProvenance: Codable, Hashable, Sendable {
    public static let requiredTeacherLayers = 22
    public static let requiredStudentLayers = 12
    public static let requiredTemperature = 2.0
    public static let requiredDistillAlpha = 0.7

    public let teacherCheckpointSHA256: String
    public let teacherLayers: Int
    public let studentLayers: Int
    public let temperature: Double
    public let distillAlpha: Double

    public init(
        teacherCheckpointSHA256: String,
        teacherLayers: Int,
        studentLayers: Int,
        temperature: Double,
        distillAlpha: Double
    ) {
        self.teacherCheckpointSHA256 = teacherCheckpointSHA256
        self.teacherLayers = teacherLayers
        self.studentLayers = studentLayers
        self.temperature = temperature
        self.distillAlpha = distillAlpha
    }

    /// The release contract for the Sift 1.4 student. Keep this stricter than
    /// the general trainer sanity checks so an eligible release cannot silently
    /// change its teacher depth or distillation recipe.
    public var isReleaseQualified: Bool {
        guard
            teacherLayers == Self.requiredTeacherLayers,
            studentLayers == Self.requiredStudentLayers,
            abs(temperature - Self.requiredTemperature) < 0.000001,
            abs(distillAlpha - Self.requiredDistillAlpha) < 0.000001,
            teacherCheckpointSHA256.count == 64,
            teacherCheckpointSHA256.unicodeScalars.allSatisfy({ scalar in
                (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
            })
        else {
            return false
        }
        return true
    }
}

/// Immutable model-selection rules shared by remote downloads and installed
/// model discovery. Older releases remain readable through the compatibility
/// catalog; the current Sift 1.4 line must be the qualified distilled student.
public enum TransformerSignalReleaseContract {
    public static let distilledReleaseSequence = 4
    public static let distilledMinimumAppBuild = 19

    public static func accepts(_ manifest: TransformerModelManifest) -> Bool {
        if manifest.modelABI == MappedTokenEmbedding.modelABI {
            guard manifest.minimumAppBuild >= MappedTokenEmbedding.minimumAppBuild,
                  manifest.releaseSequence >= 5,
                  manifest.modelArtifact.hasSuffix(".mlpackage"),
                  manifest.remoteArtifacts.contains(where: {
                      $0.path == manifest.modelArtifact + "/" + MappedTokenEmbedding.relativePath
                  }) else { return false }
        }
        guard manifest.releaseSequence >= distilledReleaseSequence else {
            return true
        }
        guard
            manifest.minimumAppBuild >= distilledMinimumAppBuild,
            manifest.algorithm == "teacher-student-distillation",
            let distillation = manifest.distillation,
            distillation.isReleaseQualified
        else {
            return false
        }
        return true
    }
}

/// Release metadata for the downloadable transformer Core ML model.
public struct TransformerModelManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let releaseSequence: Int
    public let modelABI: String
    public let minimumAppBuild: Int
    public let maximumAppBuild: Int
    public let minimumOSVersion: String
    public let runtimeProfile: TransformerRuntimeProfile
    public let quantizationProfile: TransformerQuantizationProfile
    public let validationMetrics: TransformerValidationMetrics
    public let distillation: TransformerDistillationProvenance?
    public let version: String
    public let trainedAt: String
    public let algorithm: String
    public let backbone: String
    public let languages: [String]
    public let labels: [String]
    public let maxSequenceLength: Int
    public let doLowerCase: Bool
    public let tokenizerKind: String
    public let tokenizerArtifact: String
    public let modelArtifact: String
    public let sha256: String
    public let taxonomyHash: String
    public let tokenizerSHA256: String
    public let keyID: String?
    public let signature: String?
    public let remoteBaseURL: String?
    public let remoteArtifacts: [TransformerRemoteArtifact]
    public let downloadBytes: Int64

    public init(
        schemaVersion: Int = 1,
        releaseSequence: Int = 0,
        modelABI: String = "legacy-mmbert-v1",
        minimumAppBuild: Int = 0,
        maximumAppBuild: Int = .max,
        minimumOSVersion: String = "18.0",
        runtimeProfile: TransformerRuntimeProfile = TransformerRuntimeProfile(),
        quantizationProfile: TransformerQuantizationProfile = .legacyInt8,
        validationMetrics: TransformerValidationMetrics = .unavailable,
        version: String,
        trainedAt: String,
        algorithm: String,
        backbone: String,
        languages: [String],
        labels: [String],
        maxSequenceLength: Int,
        doLowerCase: Bool,
        tokenizerKind: String,
        tokenizerArtifact: String,
        modelArtifact: String,
        sha256: String,
        taxonomyHash: String,
        tokenizerSHA256: String = "",
        keyID: String? = nil,
        signature: String? = nil,
        remoteBaseURL: String? = nil,
        remoteArtifacts: [TransformerRemoteArtifact],
        downloadBytes: Int64,
        distillation: TransformerDistillationProvenance? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.releaseSequence = releaseSequence
        self.modelABI = modelABI
        self.minimumAppBuild = minimumAppBuild
        self.maximumAppBuild = maximumAppBuild
        self.minimumOSVersion = minimumOSVersion
        self.runtimeProfile = runtimeProfile
        self.quantizationProfile = quantizationProfile
        self.validationMetrics = validationMetrics
        self.distillation = distillation
        self.version = version
        self.trainedAt = trainedAt
        self.algorithm = algorithm
        self.backbone = backbone
        self.languages = languages
        self.labels = labels
        self.maxSequenceLength = maxSequenceLength
        self.doLowerCase = doLowerCase
        self.tokenizerKind = tokenizerKind
        self.tokenizerArtifact = tokenizerArtifact
        self.modelArtifact = modelArtifact
        self.sha256 = sha256
        self.taxonomyHash = taxonomyHash
        self.tokenizerSHA256 = tokenizerSHA256
        self.keyID = keyID
        self.signature = signature
        self.remoteBaseURL = remoteBaseURL
        self.remoteArtifacts = remoteArtifacts
        self.downloadBytes = downloadBytes
    }

    public var artifactIdentity: ModelArtifactIdentity {
        ModelArtifactIdentity(
            variant: .transformer,
            modelABI: modelABI,
            releaseSequence: releaseSequence,
            sha256: sha256
        )
    }

    public func canonicalPayload() -> Data {
        let unsigned = TransformerModelManifest(
            schemaVersion: schemaVersion,
            releaseSequence: releaseSequence,
            modelABI: modelABI,
            minimumAppBuild: minimumAppBuild,
            maximumAppBuild: maximumAppBuild,
            minimumOSVersion: minimumOSVersion,
            runtimeProfile: runtimeProfile,
            quantizationProfile: quantizationProfile,
            validationMetrics: validationMetrics,
            version: version,
            trainedAt: trainedAt,
            algorithm: algorithm,
            backbone: backbone,
            languages: languages,
            labels: labels,
            maxSequenceLength: maxSequenceLength,
            doLowerCase: doLowerCase,
            tokenizerKind: tokenizerKind,
            tokenizerArtifact: tokenizerArtifact,
            modelArtifact: modelArtifact,
            sha256: sha256,
            taxonomyHash: taxonomyHash,
            tokenizerSHA256: tokenizerSHA256,
            keyID: keyID,
            signature: nil,
            remoteBaseURL: remoteBaseURL,
            remoteArtifacts: remoteArtifacts,
            downloadBytes: downloadBytes,
            distillation: distillation
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(unsigned)) ?? Data()
    }

    /// Canonical payload used by manifests published before distillation
    /// provenance was added to the signed contract. It is only used as a
    /// migration fallback when verifying an already-published manifest.
    public func legacyCanonicalPayload() -> Data {
        let unsigned = TransformerModelManifest(
            schemaVersion: schemaVersion,
            releaseSequence: releaseSequence,
            modelABI: modelABI,
            minimumAppBuild: minimumAppBuild,
            maximumAppBuild: maximumAppBuild,
            minimumOSVersion: minimumOSVersion,
            runtimeProfile: runtimeProfile,
            quantizationProfile: quantizationProfile,
            validationMetrics: validationMetrics,
            version: version,
            trainedAt: trainedAt,
            algorithm: algorithm,
            backbone: backbone,
            languages: languages,
            labels: labels,
            maxSequenceLength: maxSequenceLength,
            doLowerCase: doLowerCase,
            tokenizerKind: tokenizerKind,
            tokenizerArtifact: tokenizerArtifact,
            modelArtifact: modelArtifact,
            sha256: sha256,
            taxonomyHash: taxonomyHash,
            tokenizerSHA256: tokenizerSHA256,
            keyID: keyID,
            signature: nil,
            remoteBaseURL: remoteBaseURL,
            remoteArtifacts: remoteArtifacts,
            downloadBytes: downloadBytes,
            distillation: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(unsigned)) ?? Data()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, releaseSequence, modelABI, minimumAppBuild, maximumAppBuild, minimumOSVersion
        case runtimeProfile, quantizationProfile, validationMetrics
        case distillation
        case version, trainedAt, algorithm, backbone, languages, labels, maxSequenceLength, doLowerCase
        case tokenizerKind, tokenizerArtifact, modelArtifact, sha256, taxonomyHash, tokenizerSHA256
        case keyID, signature, remoteBaseURL, remoteArtifacts, downloadBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.releaseSequence = try container.decodeIfPresent(Int.self, forKey: .releaseSequence) ?? 0
        self.modelABI = try container.decodeIfPresent(String.self, forKey: .modelABI) ?? "legacy-mmbert-v1"
        self.minimumAppBuild = try container.decodeIfPresent(Int.self, forKey: .minimumAppBuild) ?? 0
        self.maximumAppBuild = try container.decodeIfPresent(Int.self, forKey: .maximumAppBuild) ?? .max
        self.minimumOSVersion = try container.decodeIfPresent(String.self, forKey: .minimumOSVersion) ?? "18.0"
        self.runtimeProfile = try container.decodeIfPresent(TransformerRuntimeProfile.self, forKey: .runtimeProfile)
            ?? TransformerRuntimeProfile()
        self.quantizationProfile = try container.decodeIfPresent(TransformerQuantizationProfile.self, forKey: .quantizationProfile)
            ?? .legacyInt8
        self.validationMetrics = try container.decodeIfPresent(TransformerValidationMetrics.self, forKey: .validationMetrics)
            ?? .unavailable
        self.distillation = try container.decodeIfPresent(
            TransformerDistillationProvenance.self,
            forKey: .distillation
        )
        self.version = try container.decode(String.self, forKey: .version)
        self.trainedAt = try container.decode(String.self, forKey: .trainedAt)
        self.algorithm = try container.decode(String.self, forKey: .algorithm)
        self.backbone = try container.decode(String.self, forKey: .backbone)
        self.languages = try container.decode([String].self, forKey: .languages)
        self.labels = try container.decode([String].self, forKey: .labels)
        self.maxSequenceLength = try container.decode(Int.self, forKey: .maxSequenceLength)
        self.doLowerCase = try container.decode(Bool.self, forKey: .doLowerCase)
        self.tokenizerKind = try container.decode(String.self, forKey: .tokenizerKind)
        self.tokenizerArtifact = try container.decode(String.self, forKey: .tokenizerArtifact)
        self.modelArtifact = try container.decode(String.self, forKey: .modelArtifact)
        self.sha256 = try container.decode(String.self, forKey: .sha256)
        self.taxonomyHash = try container.decode(String.self, forKey: .taxonomyHash)
        self.tokenizerSHA256 = try container.decodeIfPresent(String.self, forKey: .tokenizerSHA256) ?? ""
        self.keyID = try container.decodeIfPresent(String.self, forKey: .keyID)
        self.signature = try container.decodeIfPresent(String.self, forKey: .signature)
        self.remoteBaseURL = try container.decodeIfPresent(String.self, forKey: .remoteBaseURL)
        self.remoteArtifacts = try container.decodeIfPresent([TransformerRemoteArtifact].self, forKey: .remoteArtifacts) ?? []
        self.downloadBytes = try container.decodeIfPresent(Int64.self, forKey: .downloadBytes) ?? 0
    }
}

public typealias TransformerReleaseManifestV2 = TransformerModelManifest

public struct TransformerChannelManifestV2: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let releaseSequence: Int
    public let releaseID: String
    public let releaseManifestURL: String
    public let releaseManifestSHA256: String
    public let modelABI: String
    public let minimumAppBuild: Int
    public let maximumAppBuild: Int
    public let minimumOSVersion: String
    public let downloadBytes: Int64
    public let keyID: String
    public let signature: String?
    public let compatibleReleases: [TransformerChannelManifestV2]?
    public let catalogKeyID: String?
    public let catalogSignature: String?

    public init(
        schemaVersion: Int = 2,
        releaseSequence: Int,
        releaseID: String,
        releaseManifestURL: String,
        releaseManifestSHA256: String,
        modelABI: String,
        minimumAppBuild: Int,
        maximumAppBuild: Int,
        minimumOSVersion: String,
        downloadBytes: Int64 = 0,
        keyID: String,
        signature: String? = nil,
        compatibleReleases: [TransformerChannelManifestV2]? = nil,
        catalogKeyID: String? = nil,
        catalogSignature: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.releaseSequence = releaseSequence
        self.releaseID = releaseID
        self.releaseManifestURL = releaseManifestURL
        self.releaseManifestSHA256 = releaseManifestSHA256
        self.modelABI = modelABI
        self.minimumAppBuild = minimumAppBuild
        self.maximumAppBuild = maximumAppBuild
        self.minimumOSVersion = minimumOSVersion
        self.downloadBytes = downloadBytes
        self.keyID = keyID
        self.signature = signature
        self.compatibleReleases = compatibleReleases
        self.catalogKeyID = catalogKeyID
        self.catalogSignature = catalogSignature
    }

    public func canonicalPayload() -> Data {
        let unsigned = TransformerChannelManifestV2(
            schemaVersion: schemaVersion,
            releaseSequence: releaseSequence,
            releaseID: releaseID,
            releaseManifestURL: releaseManifestURL,
            releaseManifestSHA256: releaseManifestSHA256,
            modelABI: modelABI,
            minimumAppBuild: minimumAppBuild,
            maximumAppBuild: maximumAppBuild,
            minimumOSVersion: minimumOSVersion,
            downloadBytes: downloadBytes,
            keyID: keyID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(unsigned)) ?? Data()
    }

    public var releaseEntry: TransformerChannelManifestV2 {
        TransformerChannelManifestV2(
            schemaVersion: schemaVersion,
            releaseSequence: releaseSequence,
            releaseID: releaseID,
            releaseManifestURL: releaseManifestURL,
            releaseManifestSHA256: releaseManifestSHA256,
            modelABI: modelABI,
            minimumAppBuild: minimumAppBuild,
            maximumAppBuild: maximumAppBuild,
            minimumOSVersion: minimumOSVersion,
            downloadBytes: downloadBytes,
            keyID: keyID,
            signature: signature
        )
    }

    public func canonicalCatalogPayload() -> Data? {
        guard let compatibleReleases, !compatibleReleases.isEmpty else {
            return nil
        }
        let payload = TransformerChannelCatalogPayload(
            compatibleReleases: compatibleReleases.map(\.releaseEntry)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(payload)
    }
}

private struct TransformerChannelCatalogPayload: Encodable {
    let compatibleReleases: [TransformerChannelManifestV2]
}

public enum TransformerUpdateState: Hashable, Sendable {
    case unknown
    case checking
    case current
    case updateAvailable(TransformerChannelManifestV2)
    case requiresAppUpdate(TransformerChannelManifestV2)
    case incompatible(TransformerChannelManifestV2)
    case failed(String)
}

struct TransformerClassifierLoadAttempt: Sendable {
    let classifier: (any MessageClassifier)?
    let tokenizerMilliseconds: Int
    let modelInitializationMilliseconds: Int
}

public struct SignalModelInstallationPrimeMetrics: Codable, Hashable, Sendable {
    public let artifactIdentity: ModelArtifactIdentity
    public let succeeded: Bool
    public let totalMilliseconds: Int
    public let tokenizerMilliseconds: Int
    public let modelInitializationMilliseconds: Int
    public let inferenceMilliseconds: Int

    public init(
        artifactIdentity: ModelArtifactIdentity,
        succeeded: Bool,
        totalMilliseconds: Int,
        tokenizerMilliseconds: Int,
        modelInitializationMilliseconds: Int,
        inferenceMilliseconds: Int
    ) {
        self.artifactIdentity = artifactIdentity
        self.succeeded = succeeded
        self.totalMilliseconds = totalMilliseconds
        self.tokenizerMilliseconds = tokenizerMilliseconds
        self.modelInitializationMilliseconds = modelInitializationMilliseconds
        self.inferenceMilliseconds = inferenceMilliseconds
    }
}

public enum TransformerClassifierLoader {
    public static let defaultResourceName = "SiftSignalModel"
    public static let legacyResourceNames = ["SiftTransformerClassifier"]

    public static var compatibleResourceNames: [String] {
        [defaultResourceName] + legacyResourceNames
    }

    public static func installedModel(
        resourceName: String = defaultResourceName,
        fileManager: FileManager = .default,
        validateChecksums: Bool = true
    ) -> InstalledTransformerModel? {
        #if os(iOS)
        // Never accept the per-process Application Support fallback on iOS.
        // The app and extension can share Signal only through the entitled
        // App Group container.
        guard ModelSelectionStore.sharedContainerURL(fileManager: fileManager) != nil else {
            return nil
        }
        #endif
        let resourceNames = resourceName == defaultResourceName
            ? compatibleResourceNames
            : [resourceName]
        for candidateResourceName in resourceNames {
            if let installed = TransformerModelStore.installedModel(
                resourceName: candidateResourceName,
                fileManager: fileManager,
                validateChecksums: validateChecksums
            ) {
                return installed
            }
        }
        return nil
    }

    public static func manifest(
        resourceName: String = defaultResourceName,
        fileManager: FileManager = .default
    ) -> TransformerModelManifest? {
        installedModel(
            resourceName: resourceName,
            fileManager: fileManager,
            validateChecksums: false
        )?.manifest
    }

    public static func isAvailable(
        resourceName: String = defaultResourceName,
        fileManager: FileManager = .default
    ) -> Bool {
        isDownloadedModelReady(resourceName: resourceName, fileManager: fileManager)
    }

    public static func available(
        resourceName: String = defaultResourceName,
        confidenceThreshold: Double = 0.5
    ) -> (any MessageClassifier)? {
        downloaded(resourceName: resourceName, confidenceThreshold: confidenceThreshold)
    }

    public static func downloaded(
        resourceName: String = defaultResourceName,
        confidenceThreshold: Double = 0.5
    ) -> (any MessageClassifier)? {
        guard let installed = installedModel(
            resourceName: resourceName,
            fileManager: .default,
            validateChecksums: false
        ) else {
            return nil
        }
        return downloaded(
            installed: installed,
            fallbackResourceName: resourceName,
            confidenceThreshold: confidenceThreshold
        )
    }

    static func downloaded(
        installed: InstalledTransformerModel,
        fallbackResourceName: String = defaultResourceName,
        confidenceThreshold: Double = 0.5
    ) -> (any MessageClassifier)? {
        loadDownloaded(
            installed: installed,
            fallbackResourceName: fallbackResourceName,
            confidenceThreshold: confidenceThreshold
        ).classifier
    }

    /// Loads the already validated model from its final active URL and runs one
    /// synthetic prediction so Core ML can persist path-specific specialization
    /// artifacts before the MessageFilter extension is launched. The classifier
    /// is released before this method returns; message handling never repeats
    /// this installation-time prime.
    @discardableResult
    public static func primeInstalledModel(
        resourceName: String = defaultResourceName,
        fileManager: FileManager = .default
    ) -> SignalModelInstallationPrimeMetrics? {
        #if canImport(CoreML)
        let clock = ContinuousClock()
        let startedAt = clock.now
        guard let installed = installedModel(
            resourceName: resourceName,
            fileManager: fileManager,
            validateChecksums: false
        ) else {
            return nil
        }
        return autoreleasepool {
            let attempt = loadDownloaded(
                installed: installed,
                fallbackResourceName: resourceName
            )
            guard let classifier = attempt.classifier as? any FailureReportingMessageClassifier else {
                return SignalModelInstallationPrimeMetrics(
                    artifactIdentity: installed.manifest.artifactIdentity,
                    succeeded: false,
                    totalMilliseconds: messageFilterMilliseconds(startedAt.duration(to: clock.now)),
                    tokenizerMilliseconds: attempt.tokenizerMilliseconds,
                    modelInitializationMilliseconds: attempt.modelInitializationMilliseconds,
                    inferenceMilliseconds: 0
                )
            }
            let inferenceStartedAt = clock.now
            let succeeded = switch classifier.classificationResult(
                sender: nil,
                body: "验证码 482913"
            ) {
            case .success:
                true
            case .failure:
                false
            }
            return SignalModelInstallationPrimeMetrics(
                artifactIdentity: installed.manifest.artifactIdentity,
                succeeded: succeeded,
                totalMilliseconds: messageFilterMilliseconds(startedAt.duration(to: clock.now)),
                tokenizerMilliseconds: attempt.tokenizerMilliseconds,
                modelInitializationMilliseconds: attempt.modelInitializationMilliseconds,
                inferenceMilliseconds: messageFilterMilliseconds(inferenceStartedAt.duration(to: clock.now))
            )
        }
        #else
        return nil
        #endif
    }

    static func loadDownloaded(
        installed: InstalledTransformerModel,
        fallbackResourceName: String = defaultResourceName,
        confidenceThreshold: Double = 0.5,
        observer: MessageFilterStageObserver? = nil
    ) -> TransformerClassifierLoadAttempt {
        #if canImport(CoreML)
        // Drain Foundation/Core ML initialization temporaries before prediction.
        return autoreleasepool {
            loadDownloadedWithinPool(
                installed: installed,
                fallbackResourceName: fallbackResourceName,
                confidenceThreshold: confidenceThreshold,
                observer: observer
            )
        }
        #else
        return TransformerClassifierLoadAttempt(
            classifier: nil,
            tokenizerMilliseconds: 0,
            modelInitializationMilliseconds: 0
        )
        #endif
    }

    #if canImport(CoreML)
    private static func loadDownloadedWithinPool(
        installed: InstalledTransformerModel,
        fallbackResourceName: String,
        confidenceThreshold: Double,
        observer: MessageFilterStageObserver?
    ) -> TransformerClassifierLoadAttempt {
        guard
            installed.manifest.tokenizerKind == "bpe",
            installed.tokenizerURL.pathExtension == "siftbpe"
        else {
            return TransformerClassifierLoadAttempt(
                classifier: nil,
                tokenizerMilliseconds: 0,
                modelInitializationMilliseconds: 0
            )
        }

        let compiledURL: URL
        if installed.modelURL.pathExtension == "mlmodelc" {
            compiledURL = installed.modelURL
        } else {
            let cachedURL = TransformerModelStore.compiledModelURL(
                resourceName: installedResourceName(for: installed, fallback: fallbackResourceName),
                in: installed.directoryURL
            )
            guard FileManager.default.fileExists(atPath: cachedURL.path) else {
                return TransformerClassifierLoadAttempt(
                    classifier: nil,
                    tokenizerMilliseconds: 0,
                    modelInitializationMilliseconds: 0
                )
            }
            compiledURL = cachedURL
        }

        let clock = ContinuousClock()
        observer?(.tokenizerLoadStarted)
        let tokenizerStartedAt = clock.now
        let tokenizer: any TextTokenizing
        do {
            tokenizer = try makeTokenizer(manifest: installed.manifest, tokenizerURL: installed.tokenizerURL)
        } catch {
            return TransformerClassifierLoadAttempt(
                classifier: nil,
                tokenizerMilliseconds: messageFilterMilliseconds(tokenizerStartedAt.duration(to: clock.now)),
                modelInitializationMilliseconds: 0
            )
        }
        let tokenizerMilliseconds = messageFilterMilliseconds(tokenizerStartedAt.duration(to: clock.now))
        observer?(.tokenizerLoaded)

        observer?(.modelLoadStarted)
        let modelStartedAt = clock.now
        let classifier: TransformerTextClassifier
        do {
            classifier = try TransformerTextClassifier(
                modelURL: compiledURL,
                tokenizer: tokenizer,
                labels: installed.manifest.labels,
                confidenceThreshold: confidenceThreshold,
                computeUnits: installed.manifest.runtimeProfile.computeUnits,
                embeddingURL: installed.embeddingURL
            )
        } catch {
            return TransformerClassifierLoadAttempt(
                classifier: nil,
                tokenizerMilliseconds: tokenizerMilliseconds,
                modelInitializationMilliseconds: messageFilterMilliseconds(
                    modelStartedAt.duration(to: clock.now)
                )
            )
        }
        let modelInitializationMilliseconds = messageFilterMilliseconds(modelStartedAt.duration(to: clock.now))
        observer?(.modelLoaded)
        return TransformerClassifierLoadAttempt(
            classifier: classifier,
            tokenizerMilliseconds: tokenizerMilliseconds,
            modelInitializationMilliseconds: modelInitializationMilliseconds
        )
    }
    #endif

    public static func isDownloadedModelAvailable(
        resourceName: String = defaultResourceName,
        fileManager: FileManager = .default
    ) -> Bool {
        installedModel(
            resourceName: resourceName,
            fileManager: fileManager,
            validateChecksums: false
        ) != nil
    }

    public static func isDownloadedModelReady(
        resourceName: String = defaultResourceName,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let installed = installedModel(
            resourceName: resourceName,
            fileManager: fileManager,
            validateChecksums: false
        ) else {
            return false
        }
        return isReady(installed, resourceName: resourceName, fileManager: fileManager)
    }

    public static func isReady(
        _ installed: InstalledTransformerModel,
        resourceName: String = defaultResourceName,
        fileManager: FileManager = .default
    ) -> Bool {
        if installed.modelURL.pathExtension == "mlmodelc" {
            return true
        }
        let resolvedResourceName = installedResourceName(for: installed, fallback: resourceName)
        return fileManager.fileExists(atPath: TransformerModelStore.compiledModelURL(
            resourceName: resolvedResourceName,
            in: installed.directoryURL,
            fileManager: fileManager
        ).path)
    }

    public static func prepareDownloadedModel(
        in directory: URL,
        resourceName: String = defaultResourceName,
        fileManager: FileManager = .default,
        validatesRuntime: Bool = true
    ) throws {
        #if canImport(CoreML)
        guard
            let installed = TransformerModelStore.model(
                in: directory,
                resourceName: resourceName,
                fileManager: fileManager,
                validateChecksums: false
            ),
            installed.manifest.tokenizerKind == "bpe",
            installed.tokenizerURL.pathExtension == "siftbpe"
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard installed.modelURL.pathExtension != "mlmodelc" else {
            if validatesRuntime {
                try smokeTestDownloadedModel(installed: installed, modelURL: installed.modelURL)
            }
            return
        }

        let targetURL = TransformerModelStore.compiledModelURL(
            resourceName: resourceName,
            in: directory,
            fileManager: fileManager
        )
        if !fileManager.fileExists(atPath: targetURL.path) {
            let compiledURL = try MLModel.compileModel(at: installed.modelURL)
            do {
                try fileManager.moveItem(at: compiledURL, to: targetURL)
            } catch {
                try? fileManager.removeItem(at: compiledURL)
                throw error
            }
        }

        if validatesRuntime {
            try smokeTestDownloadedModel(installed: installed, modelURL: targetURL)
        }
        #endif
    }

    #if canImport(CoreML)
    private static func smokeTestDownloadedModel(
        installed: InstalledTransformerModel,
        modelURL: URL
    ) throws {
        guard !installed.manifest.labels.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let tokenizer = try makeTokenizer(
            manifest: installed.manifest,
            tokenizerURL: installed.tokenizerURL
        )
        let classifier = try TransformerTextClassifier(
            modelURL: modelURL,
            tokenizer: tokenizer,
            labels: installed.manifest.labels,
            confidenceThreshold: 0,
            computeUnits: installed.manifest.runtimeProfile.computeUnits,
            embeddingURL: installed.embeddingURL
        )
        let smokeBodies = [
            "您的验证码是 482913，请勿泄露。",
            "Your verification code is 482913. Do not share it.",
            "認証コードは482913です。他人に教えないでください。",
        ]
        for body in smokeBodies {
            let decision = classifier.classify(sender: nil, body: body)
            guard
                decision.source == .model,
                decision.confidence.isFinite,
                decision.confidence >= 0,
                decision.confidence <= 1,
                installed.manifest.labels.contains(decision.labelID)
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }
    #endif

    static func makeTokenizer(manifest: TransformerModelManifest, tokenizerURL: URL) throws -> any TextTokenizing {
        guard manifest.tokenizerKind == "bpe", tokenizerURL.pathExtension == "siftbpe" else {
            throw BPETokenizer.TokenizerError.invalidCompactArtifact
        }
        return try BPETokenizer(
            tokenizerURL: tokenizerURL,
            configuration: BPETokenizer.Configuration(maxSequenceLength: manifest.maxSequenceLength)
        )
    }

    private static func installedResourceName(
        for installed: InstalledTransformerModel,
        fallback: String
    ) -> String {
        compatibleResourceNames.first(where: {
            installed.manifestURL.lastPathComponent == "\($0).manifest.json"
        }) ?? fallback
    }
}

#if canImport(CoreML)
public enum TransformerModelContract {
    public static let abstainLabel = ModelOutputContract.abstainLabel

    public static func isAbstainLabel(_ label: String) -> Bool {
        ModelOutputContract.isAbstainLabel(label)
    }
}

/// Runs the exported transformer classifier.
///
/// The Core ML model takes tokenizer-produced `input_ids` / `attention_mask` tensors
/// of shape `[1, maxSequenceLength]` and is exported either as a Core ML
/// classifier (predicted label + probability dictionary) or as a plain
/// `probabilities` tensor matched against the manifest's label order.
public final class TransformerTextClassifier: StageReportingMessageClassifier, @unchecked Sendable {
    // A shared cached model must not allocate overlapping prediction workspaces.
    private let predictionLock = NSLock()
    private let model: MLModel
    private let tokenizer: any TextTokenizing
    private let labels: [String]
    private let confidenceThreshold: Double
    private let inputIDsName: String
    private let attentionMaskName: String?
    private let embedding: MappedTokenEmbedding?

    public init(
        modelURL: URL,
        tokenizer: any TextTokenizing,
        labels: [String],
        confidenceThreshold: Double = 0.5,
        computeUnits: String = "all",
        embeddingURL: URL? = nil
    ) throws {
        let configuration = MLModelConfiguration()
        guard let resolvedComputeUnits = Self.computeUnits(named: computeUnits) else {
            throw CocoaError(.featureUnsupported)
        }
        configuration.computeUnits = resolvedComputeUnits
        // Signal always supplies the fixed [1, 96] token shape. Tell Core ML
        // shape switching is rare so specialization can avoid retaining the
        // fast shape-switching workspace used by flexible-input models.
        var optimizationHints = MLOptimizationHints()
        optimizationHints.reshapeFrequency = .infrequent
        configuration.optimizationHints = optimizationHints
        configuration.modelDisplayName = "Sift Signal"
        self.model = try MLModel(contentsOf: modelURL, configuration: configuration)
        self.tokenizer = tokenizer
        self.labels = labels
        self.confidenceThreshold = confidenceThreshold

        let inputs = model.modelDescription.inputDescriptionsByName
        self.inputIDsName = inputs["input_ids"] != nil ? "input_ids"
            : (inputs.keys.first { $0 != MappedTokenEmbedding.inputName && $0.lowercased().contains("input") } ?? "input_ids")
        self.attentionMaskName = inputs.keys.first { $0.lowercased().contains("mask") }
        self.embedding = try embeddingURL.map { try MappedTokenEmbedding(url: $0) }
        if let embedding {
            guard let constraint = inputs[MappedTokenEmbedding.inputName]?.multiArrayConstraint,
                  constraint.dataType == .float32, constraint.shape.count == 3,
                  constraint.shape[0].intValue == 1, constraint.shape[2].intValue == embedding.width else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } else if inputs[MappedTokenEmbedding.inputName] != nil {
            throw CocoaError(.fileReadNoSuchFile)
        }
    }

    private static func computeUnits(named identifier: String) -> MLComputeUnits? {
        switch identifier {
        case "all": return .all
        case "cpuOnly": return .cpuOnly
        case "cpuAndGPU": return .cpuAndGPU
        case "cpuAndNeuralEngine": return .cpuAndNeuralEngine
        default: return nil
        }
    }

    public func classify(sender: String?, body: String) -> ClassificationDecision {
        switch classificationResult(sender: sender, body: body) {
        case let .success(decision):
            return decision
        case .failure:
            return fallbackDecision(confidence: 0)
        }
    }

    public func classificationResult(
        sender: String?,
        body: String
    ) -> Result<ClassificationDecision, MessageClassifierInferenceFailure> {
        classificationResult(sender: sender, body: body, observer: nil)
    }

    public func classificationResult(
        sender: String?,
        body: String,
        observer: MessageFilterStageObserver?
    ) -> Result<ClassificationDecision, MessageClassifierInferenceFailure> {
        predictionLock.lock()
        defer { predictionLock.unlock() }
        return autoreleasepool {
            predictionResult(body: body, observer: observer)
        }
    }

    private func predictionResult(
        body: String,
        observer: MessageFilterStageObserver?
    ) -> Result<ClassificationDecision, MessageClassifierInferenceFailure> {
        do {
            observer?(.tokenizationStarted)
            let encoded = tokenizer.tokenizeText(body)
            observer?(.tokenizationFinished)
            var features: [String: MLFeatureValue] = [
                inputIDsName: MLFeatureValue(multiArray: try multiArray(from: encoded.inputIDs))
            ]
            if let attentionMaskName {
                features[attentionMaskName] = MLFeatureValue(multiArray: try multiArray(from: encoded.attentionMask))
            }
            if let embedding {
                observer?(.embeddingStarted)
                let tensor = try MLMultiArray(
                    shape: [1, NSNumber(value: encoded.inputIDs.count), NSNumber(value: embedding.width)],
                    dataType: .float32
                )
                guard tensor.strides[2].intValue == 1,
                      tensor.strides[1].intValue == embedding.width else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try embedding.decode(tokenIDs: encoded.inputIDs, into: UnsafeMutableBufferPointer(
                    start: tensor.dataPointer.assumingMemoryBound(to: Float.self), count: tensor.count
                ))
                features[MappedTokenEmbedding.inputName] = MLFeatureValue(multiArray: tensor)
                observer?(.embeddingFinished)
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: features)
            observer?(.predictionStarted)
            let output = try model.prediction(from: provider)
            observer?(.predictionFinished)
            guard let best = bestPrediction(from: output) else {
                return .failure(.invalidOutput)
            }
            guard best.confidence.isFinite, (0...1).contains(best.confidence) else {
                return .failure(.invalidOutput)
            }

            if TransformerModelContract.isAbstainLabel(best.label) {
                return .success(ModelOutputContract.abstentionDecision(confidence: best.confidence))
            }

            guard let leaf = SiftTaxonomy.leaf(id: best.label) else {
                return .failure(.invalidOutput)
            }
            guard best.confidence >= confidenceThreshold else {
                return .success(fallbackDecision(confidence: best.confidence))
            }

            return .success(ClassificationDecision(
                labelID: leaf.id,
                labelTitle: leaf.title,
                groupID: leaf.groupId,
                groupTitle: leaf.groupTitle,
                confidence: best.confidence,
                systemAction: leaf.systemAction,
                source: .model
            ))
        } catch {
            return .failure(.predictionFailed)
        }
    }

    private func bestPrediction(from output: MLFeatureProvider) -> (label: String, confidence: Double)? {
        // Core ML classifier flavor: predicted label + probability dictionary.
        if
            let predictedName = model.modelDescription.predictedFeatureName,
            let label = output.featureValue(for: predictedName)?.stringValue
        {
            var confidence = confidenceThreshold
            if
                let probabilitiesName = model.modelDescription.predictedProbabilitiesName,
                let probabilities = output.featureValue(for: probabilitiesName)?.dictionaryValue
            {
                confidence = probabilities[AnyHashable(label)]?.doubleValue
                    ?? probabilities[AnyHashable(label as NSString)]?.doubleValue
                    ?? confidence
            }
            return (label, confidence)
        }

        // Plain tensor flavor: probabilities aligned with manifest labels.
        for name in output.featureNames {
            guard
                let array = output.featureValue(for: name)?.multiArrayValue,
                array.count == labels.count
            else {
                continue
            }
            var bestIndex = 0
            var bestValue = -Double.infinity
            for index in 0..<array.count {
                let value = array[index].doubleValue
                if value > bestValue {
                    bestValue = value
                    bestIndex = index
                }
            }
            return (labels[bestIndex], bestValue)
        }
        return nil
    }

    private func multiArray(from values: [Int32]) throws -> MLMultiArray {
        MLMultiArray(MLShapedArray<Int32>(scalars: values, shape: [1, values.count]))
    }

    private func fallbackDecision(confidence: Double) -> ClassificationDecision {
        let fallback = SiftTaxonomy.leaf(id: "transaction.other") ?? SiftTaxonomy.leaves[0]
        return ClassificationDecision(
            labelID: fallback.id,
            labelTitle: fallback.title,
            groupID: fallback.groupId,
            groupTitle: fallback.groupTitle,
            confidence: confidence,
            systemAction: .none,
            source: .fallback
        )
    }
}
#endif
