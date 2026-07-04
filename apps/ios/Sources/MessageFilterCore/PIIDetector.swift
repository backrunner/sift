import Foundation

#if canImport(CoreML)
import CoreML
#endif

/// Categories of sensitive information the sanitizer can redact. Raw values
/// match the token-classification tags emitted by `tools/pii-trainer`.
public enum PIIKind: String, Codable, CaseIterable, Sendable {
    case phone = "PHONE"
    case url = "URL"
    case email = "EMAIL"
    case address = "ADDRESS"
    case card = "CARD"
    case idNumber = "ID"
    case orderID = "ORDER_ID"
    case amount = "AMOUNT"
    case code = "CODE"
    case name = "NAME"

    public var token: String {
        "{{\(rawValue)}}"
    }
}

public struct PIIDetection: Hashable, Sendable {
    public let kind: PIIKind
    public let range: Range<String.Index>

    public init(kind: PIIKind, range: Range<String.Index>) {
        self.kind = kind
        self.range = range
    }
}

/// A model-based PII detector. The sanitizer unions these detections with its
/// regex rules — the model widens recall, the rules guarantee a floor.
public protocol PIIDetecting: Sendable {
    func detections(in text: String) -> [PIIDetection]
}

public enum PIIDetectorLoader {
    public static let defaultResourceName = "SiftPIIDetector"

    public static func manifest(
        resourceName: String = defaultResourceName,
        bundles: [Bundle] = [.main]
    ) -> TransformerModelManifest? {
        TransformerClassifierLoader.manifest(resourceName: resourceName, bundles: bundles)
    }

    public static func isAvailable(
        resourceName: String = defaultResourceName,
        bundles: [Bundle] = [.main]
    ) -> Bool {
        TransformerClassifierLoader.isAvailable(resourceName: resourceName, bundles: bundles)
    }

    /// Loads the optional bundled PII model; nil (rules-only sanitization)
    /// when the artifacts are not shipped or fail to load.
    public static func bundled(
        resourceName: String = defaultResourceName,
        bundles: [Bundle] = [.main],
        confidenceThreshold: Double = 0.6
    ) -> (any PIIDetecting)? {
        #if canImport(CoreML)
        guard
            let manifest = manifest(resourceName: resourceName, bundles: bundles),
            let vocabularyURL = TransformerClassifierLoader.vocabularyURL(
                manifest: manifest,
                resourceName: resourceName,
                bundles: bundles
            ),
            let modelURL = TransformerClassifierLoader.modelURL(resourceName: resourceName, bundles: bundles)
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
            let compiledURL = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
            return try CoreMLPIIDetector(
                modelURL: compiledURL,
                tokenizer: tokenizer,
                tags: manifest.labels,
                confidenceThreshold: confidenceThreshold
            )
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(CoreML)
/// Token-classification PII detector: WordPiece-encodes the text, runs the
/// Core ML model (logits `[1, seq, tags]`), softmaxes per position, and
/// projects confident non-`O` tags back onto whole-word character ranges.
/// Adjacent words with the same tag merge into one detection.
public final class CoreMLPIIDetector: PIIDetecting, @unchecked Sendable {
    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private let tags: [String]
    private let confidenceThreshold: Double
    private let inputIDsName: String
    private let attentionMaskName: String?

    public init(
        modelURL: URL,
        tokenizer: WordPieceTokenizer,
        tags: [String],
        confidenceThreshold: Double = 0.6
    ) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        self.model = try MLModel(contentsOf: modelURL, configuration: configuration)
        self.tokenizer = tokenizer
        self.tags = tags
        self.confidenceThreshold = confidenceThreshold

        let inputs = model.modelDescription.inputDescriptionsByName
        self.inputIDsName = inputs.keys.first { $0.lowercased().contains("input") } ?? "input_ids"
        self.attentionMaskName = inputs.keys.first { $0.lowercased().contains("mask") }
    }

    public func detections(in text: String) -> [PIIDetection] {
        guard !text.isEmpty else {
            return []
        }
        do {
            let encoded = tokenizer.encodeWithOffsets(text)
            var features: [String: MLFeatureValue] = [
                inputIDsName: MLFeatureValue(multiArray: multiArray(from: encoded.inputIDs))
            ]
            if let attentionMaskName {
                features[attentionMaskName] = MLFeatureValue(multiArray: multiArray(from: encoded.attentionMask))
            }

            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
            guard let logits = logitsArray(from: output, sequenceLength: encoded.inputIDs.count) else {
                return []
            }

            let wordKinds = classifyWords(encoded: encoded, logits: logits)
            return mergeAdjacent(wordKinds: wordKinds, wordRanges: encoded.wordRanges)
        } catch {
            return []
        }
    }

    // MARK: - Internals

    private func logitsArray(from output: MLFeatureProvider, sequenceLength: Int) -> MLMultiArray? {
        for name in output.featureNames {
            guard let array = output.featureValue(for: name)?.multiArrayValue else {
                continue
            }
            if array.count == sequenceLength * tags.count {
                return array
            }
        }
        return nil
    }

    /// Majority tag across a word's pieces; a word counts as PII only when
    /// its best piece clears the softmax confidence threshold.
    private func classifyWords(
        encoded: WordPieceTokenizer.EncodedTextWithOffsets,
        logits: MLMultiArray
    ) -> [PIIKind?] {
        var wordKinds: [PIIKind?] = Array(repeating: nil, count: encoded.wordRanges.count)
        var bestConfidence: [Double] = Array(repeating: 0, count: encoded.wordRanges.count)

        for position in 0..<encoded.wordIndices.count {
            guard let wordIndex = encoded.wordIndices[position] else {
                continue
            }
            let (tagIndex, probability) = argmaxSoftmax(logits: logits, position: position)
            guard
                probability >= confidenceThreshold,
                tagIndex < tags.count,
                let kind = PIIKind(rawValue: normalizedTag(tags[tagIndex]))
            else {
                continue
            }
            if probability > bestConfidence[wordIndex] {
                bestConfidence[wordIndex] = probability
                wordKinds[wordIndex] = kind
            }
        }
        return wordKinds
    }

    /// Accepts plain (`PHONE`) and BIO-style (`B-PHONE` / `I-PHONE`) tags.
    private func normalizedTag(_ tag: String) -> String {
        if tag.hasPrefix("B-") || tag.hasPrefix("I-") {
            return String(tag.dropFirst(2))
        }
        return tag
    }

    private func argmaxSoftmax(logits: MLMultiArray, position: Int) -> (index: Int, probability: Double) {
        let offset = position * tags.count
        var maxLogit = -Double.infinity
        var maxIndex = 0
        var values: [Double] = []
        values.reserveCapacity(tags.count)
        for tagIndex in 0..<tags.count {
            let value = logits[offset + tagIndex].doubleValue
            values.append(value)
            if value > maxLogit {
                maxLogit = value
                maxIndex = tagIndex
            }
        }
        let expSum = values.reduce(0) { $0 + exp($1 - maxLogit) }
        return (maxIndex, 1.0 / expSum)
    }

    private func mergeAdjacent(wordKinds: [PIIKind?], wordRanges: [Range<String.Index>]) -> [PIIDetection] {
        var detections: [PIIDetection] = []
        var index = 0
        while index < wordKinds.count {
            guard let kind = wordKinds[index] else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < wordKinds.count, wordKinds[end + 1] == kind {
                end += 1
            }
            detections.append(PIIDetection(
                kind: kind,
                range: wordRanges[index].lowerBound..<wordRanges[end].upperBound
            ))
            index = end + 1
        }
        return detections
    }

    private func multiArray(from values: [Int32]) -> MLMultiArray {
        MLMultiArray(MLShapedArray<Int32>(scalars: values, shape: [1, values.count]))
    }
}
#endif
