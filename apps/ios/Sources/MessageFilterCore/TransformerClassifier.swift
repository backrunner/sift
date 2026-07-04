import Foundation

#if canImport(CoreML)
import CoreML
#endif

/// Sidecar metadata for the bundled SetFit/transformer Core ML model.
public struct TransformerModelManifest: Codable, Hashable, Sendable {
    public let version: String
    public let trainedAt: String
    public let algorithm: String
    public let backbone: String
    public let languages: [String]
    public let labels: [String]
    public let maxSequenceLength: Int
    public let doLowerCase: Bool
    public let vocabularyArtifact: String
    public let modelArtifact: String
    public let sha256: String?
    public let taxonomyHash: String?

    public init(
        version: String,
        trainedAt: String,
        algorithm: String,
        backbone: String,
        languages: [String],
        labels: [String],
        maxSequenceLength: Int,
        doLowerCase: Bool,
        vocabularyArtifact: String,
        modelArtifact: String,
        sha256: String? = nil,
        taxonomyHash: String? = nil
    ) {
        self.version = version
        self.trainedAt = trainedAt
        self.algorithm = algorithm
        self.backbone = backbone
        self.languages = languages
        self.labels = labels
        self.maxSequenceLength = maxSequenceLength
        self.doLowerCase = doLowerCase
        self.vocabularyArtifact = vocabularyArtifact
        self.modelArtifact = modelArtifact
        self.sha256 = sha256
        self.taxonomyHash = taxonomyHash
    }
}

public enum TransformerClassifierLoader {
    public static let defaultResourceName = "SiftTransformerClassifier"

    public static func manifest(
        resourceName: String = defaultResourceName,
        bundles: [Bundle] = [.main]
    ) -> TransformerModelManifest? {
        for bundle in bundles {
            guard let url = bundle.url(forResource: "\(resourceName).manifest", withExtension: "json") else {
                continue
            }
            if
                let data = try? Data(contentsOf: url),
                let manifest = try? JSONDecoder().decode(TransformerModelManifest.self, from: data)
            {
                return manifest
            }
        }
        return nil
    }

    /// True when every artifact needed to run the transformer variant ships
    /// in one of the given bundles.
    public static func isAvailable(
        resourceName: String = defaultResourceName,
        bundles: [Bundle] = [.main]
    ) -> Bool {
        guard let manifest = manifest(resourceName: resourceName, bundles: bundles) else {
            return false
        }
        return vocabularyURL(manifest: manifest, resourceName: resourceName, bundles: bundles) != nil
            && modelURL(resourceName: resourceName, bundles: bundles) != nil
    }

    public static func bundled(
        resourceName: String = defaultResourceName,
        bundles: [Bundle] = [.main],
        confidenceThreshold: Double = 0.5
    ) -> (any MessageClassifier)? {
        #if canImport(CoreML)
        guard
            let manifest = manifest(resourceName: resourceName, bundles: bundles),
            let vocabularyURL = vocabularyURL(manifest: manifest, resourceName: resourceName, bundles: bundles),
            let modelURL = modelURL(resourceName: resourceName, bundles: bundles)
        else {
            return nil
        }

        do {
            let tokenizer = try WordPieceTokenizer(
                vocabularyFileURL: vocabularyURL,
                configuration: WordPieceTokenizer.Configuration(
                    doLowerCase: manifest.doLowerCase,
                    maxSequenceLength: manifest.maxSequenceLength
                )
            )
            let compiledURL = try compiledModelURL(from: modelURL)
            return try TransformerTextClassifier(
                modelURL: compiledURL,
                tokenizer: tokenizer,
                labels: manifest.labels,
                confidenceThreshold: confidenceThreshold
            )
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    static func vocabularyURL(
        manifest: TransformerModelManifest,
        resourceName: String,
        bundles: [Bundle]
    ) -> URL? {
        let artifact = manifest.vocabularyArtifact as NSString
        let name = artifact.deletingPathExtension
        let ext = artifact.pathExtension.isEmpty ? "txt" : artifact.pathExtension
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    static func modelURL(resourceName: String, bundles: [Bundle]) -> URL? {
        for bundle in bundles {
            for ext in ["mlmodelc", "mlpackage", "mlmodel"] {
                if let url = bundle.url(forResource: resourceName, withExtension: ext) {
                    return url
                }
            }
        }
        return nil
    }

    #if canImport(CoreML)
    private static func compiledModelURL(from url: URL) throws -> URL {
        if url.pathExtension == "mlmodelc" {
            return url
        }
        return try MLModel.compileModel(at: url)
    }
    #endif
}

#if canImport(CoreML)
/// Runs the exported SetFit sentence-transformer classifier.
///
/// The Core ML model takes WordPiece `input_ids` / `attention_mask` tensors
/// of shape `[1, maxSequenceLength]` and is exported either as a Core ML
/// classifier (predicted label + probability dictionary) or as a plain
/// `probabilities` tensor matched against the manifest's label order.
public final class TransformerTextClassifier: MessageClassifier, @unchecked Sendable {
    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private let labels: [String]
    private let confidenceThreshold: Double
    private let inputIDsName: String
    private let attentionMaskName: String?

    public init(
        modelURL: URL,
        tokenizer: WordPieceTokenizer,
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
            let encoded = tokenizer.encode(body)
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
