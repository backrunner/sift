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

/// Release metadata for the downloadable transformer Core ML model.
public struct TransformerModelManifest: Codable, Hashable, Sendable {
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
    public let remoteBaseURL: String?
    public let remoteArtifacts: [TransformerRemoteArtifact]
    public let downloadBytes: Int64

    public init(
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
        remoteBaseURL: String? = nil,
        remoteArtifacts: [TransformerRemoteArtifact],
        downloadBytes: Int64
    ) {
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
        self.remoteBaseURL = remoteBaseURL
        self.remoteArtifacts = remoteArtifacts
        self.downloadBytes = downloadBytes
    }
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
            return
        }

        let targetURL = TransformerModelStore.compiledModelURL(
            resourceName: resourceName,
            in: directory,
            fileManager: fileManager
        )
        if fileManager.fileExists(atPath: targetURL.path) {
            return
        }
        let compiledURL = try MLModel.compileModel(at: installed.modelURL)
        do {
            try fileManager.moveItem(at: compiledURL, to: targetURL)
        } catch {
            try? fileManager.removeItem(at: compiledURL)
            throw error
        }
        #endif
    }

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
        // The message-filter extension has a tight memory budget; prefer
        // CPU+NE over GPU to avoid large staging allocations.
        configuration.computeUnits = .cpuAndNeuralEngine
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
