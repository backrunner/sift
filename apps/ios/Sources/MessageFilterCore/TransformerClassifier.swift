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
    public let computeUnits: String
    public let modelType: String
    public let transformerBudgetMilliseconds: Int

    public init(
        computeUnits: String = "all",
        modelType: String = "mlProgram",
        transformerBudgetMilliseconds: Int = 500
    ) {
        self.computeUnits = computeUnits
        self.modelType = modelType
        self.transformerBudgetMilliseconds = transformerBudgetMilliseconds
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
        downloadBytes: Int64
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
            downloadBytes: downloadBytes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(unsigned)) ?? Data()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, releaseSequence, modelABI, minimumAppBuild, maximumAppBuild, minimumOSVersion
        case runtimeProfile, quantizationProfile, validationMetrics
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
        signature: String? = nil
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

public enum TransformerClassifierLoader {
    public static let defaultResourceName = "SiftTransformerClassifier"

    public static func manifest(
        resourceName: String = defaultResourceName,
        fileManager: FileManager = .default
    ) -> TransformerModelManifest? {
        TransformerModelStore.installedModel(
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
        #if canImport(CoreML)
        guard
            let installed = TransformerModelStore.installedModel(
                resourceName: resourceName,
                validateChecksums: false
            ),
            installed.manifest.tokenizerKind == "bpe",
            installed.tokenizerURL.pathExtension == "siftbpe"
        else {
            return nil
        }

        do {
            let tokenizer = try makeTokenizer(manifest: installed.manifest, tokenizerURL: installed.tokenizerURL)
            let compiledURL: URL
            if installed.modelURL.pathExtension == "mlmodelc" {
                compiledURL = installed.modelURL
            } else {
                let cachedURL = TransformerModelStore.compiledModelURL(
                    resourceName: resourceName,
                    in: installed.directoryURL
                )
                guard FileManager.default.fileExists(atPath: cachedURL.path) else {
                    return nil
                }
                compiledURL = cachedURL
            }
            return try TransformerTextClassifier(
                modelURL: compiledURL,
                tokenizer: tokenizer,
                labels: installed.manifest.labels,
                confidenceThreshold: confidenceThreshold
            )
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    public static func isDownloadedModelAvailable(
        resourceName: String = defaultResourceName,
        fileManager: FileManager = .default
    ) -> Bool {
        TransformerModelStore.installedModel(
            resourceName: resourceName,
            fileManager: fileManager,
            validateChecksums: false
        ) != nil
    }

    public static func isDownloadedModelReady(
        resourceName: String = defaultResourceName,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let installed = TransformerModelStore.installedModel(
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
        return fileManager.fileExists(atPath: TransformerModelStore.compiledModelURL(
            resourceName: resourceName,
            in: installed.directoryURL,
            fileManager: fileManager
        ).path)
    }

    public static func prepareDownloadedModel(
        in directory: URL,
        resourceName: String = defaultResourceName,
        fileManager: FileManager = .default
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
            try smokeTestDownloadedModel(installed: installed, modelURL: installed.modelURL)
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

        try smokeTestDownloadedModel(installed: installed, modelURL: targetURL)
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
            confidenceThreshold: 0
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
public final class TransformerTextClassifier: MessageClassifier, @unchecked Sendable {
    private let model: MLModel
    private let tokenizer: any TextTokenizing
    private let labels: [String]
    private let confidenceThreshold: Double
    private let inputIDsName: String
    private let attentionMaskName: String?

    public init(
        modelURL: URL,
        tokenizer: any TextTokenizing,
        labels: [String],
        confidenceThreshold: Double = 0.5
    ) throws {
        let configuration = MLModelConfiguration()
        // Low-bit ML Programs currently produce incorrect predictions when
        // GPU fallback is excluded. Core ML still chooses the cheapest
        // supported accelerator for each operation under `.all`.
        configuration.computeUnits = .all
        self.model = try MLModel(contentsOf: modelURL, configuration: configuration)
        self.tokenizer = tokenizer
        self.labels = labels
        self.confidenceThreshold = confidenceThreshold

        let inputs = model.modelDescription.inputDescriptionsByName
        self.inputIDsName = inputs.keys.first { $0.lowercased().contains("input") } ?? "input_ids"
        self.attentionMaskName = inputs.keys.first { $0.lowercased().contains("mask") }
    }

    public func classify(sender: String?, body: String) -> ClassificationDecision {
        do {
            let encoded = tokenizer.tokenizeText(body)
            var features: [String: MLFeatureValue] = [
                inputIDsName: MLFeatureValue(multiArray: try multiArray(from: encoded.inputIDs))
            ]
            if let attentionMaskName {
                features[attentionMaskName] = MLFeatureValue(multiArray: try multiArray(from: encoded.attentionMask))
            }

            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
            guard let best = bestPrediction(from: output) else {
                return fallbackDecision(confidence: 0)
            }

            if TransformerModelContract.isAbstainLabel(best.label) {
                return ModelOutputContract.abstentionDecision(confidence: best.confidence)
            }

            guard
                let leaf = SiftTaxonomy.leaf(id: best.label),
                best.confidence >= confidenceThreshold
            else {
                return fallbackDecision(confidence: best.confidence)
            }

            return ClassificationDecision(
                labelID: leaf.id,
                labelTitle: leaf.title,
                groupID: leaf.groupId,
                groupTitle: leaf.groupTitle,
                confidence: best.confidence,
                systemAction: leaf.systemAction,
                source: .model
            )
        } catch {
            return fallbackDecision(confidence: 0)
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
