import Foundation

#if canImport(CoreML)
import CoreML
#endif

enum AmountPatterns {
    // Accept conventional thousands grouping without allowing a malformed
    // value to be partially redacted on either side of a separator.
    static let groupedNumber = #"(?<!\d)(?<!\d[,，.])\d{1,3}(?:[,，]\d{3})+(?:\.\d{1,2})?(?!\d|[,，.]\d)"#
    static let number = #"(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:\.\d{1,2})?(?!\d|[,，.]\d)"#
    static let currencyPrefixed = #"(?:[¥￥$€£]|(?:RMB|CNY|USD|EUR|GBP|JPY)(?![A-Z]))\s*"# + number
    static let currencySuffixed = #"(?<!\d)(?<!\d[,，.])"# + number
        + #"\s*(?:(?:元|块|円)|(?:USD|EUR|GBP|JPY)(?![A-Z]))"#
    static let amount = "(?:\(currencyPrefixed)|\(currencySuffixed))"
}

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

enum PIIDetectionPostprocessor {
    static func expandingGroupedAmounts(
        _ detections: [PIIDetection],
        in text: String
    ) -> [PIIDetection] {
        guard
            detections.contains(where: { $0.kind == .amount }),
            let regex = try? NSRegularExpression(pattern: AmountPatterns.groupedNumber)
        else {
            return detections
        }

        let wholeRange = NSRange(text.startIndex..., in: text)
        let groupedNumberRanges = regex.matches(in: text, range: wholeRange).compactMap {
            Range($0.range, in: text)
        }
        guard !groupedNumberRanges.isEmpty else { return detections }

        let expanded = detections.map { detection in
            guard
                detection.kind == .amount,
                let groupedRange = groupedNumberRanges.first(where: { $0.overlaps(detection.range) })
            else {
                return detection
            }
            let lowerBound = min(detection.range.lowerBound, groupedRange.lowerBound)
            let upperBound = max(detection.range.upperBound, groupedRange.upperBound)
            return PIIDetection(
                kind: .amount,
                range: lowerBound..<upperBound
            )
        }

        var merged: [PIIDetection] = []
        for detection in expanded {
            if
                let last = merged.last,
                last.kind == detection.kind,
                last.range.overlaps(detection.range)
            {
                let lowerBound = min(last.range.lowerBound, detection.range.lowerBound)
                let upperBound = max(last.range.upperBound, detection.range.upperBound)
                merged[merged.count - 1] = PIIDetection(
                    kind: last.kind,
                    range: lowerBound..<upperBound
                )
            } else {
                merged.append(detection)
            }
        }
        return merged
    }
}

/// A model-based PII detector. The sanitizer unions these detections with its
/// regex rules. This widens recall but can add false positives, so bundled
/// models must pass the trainer's clean-negative quality gate.
public protocol PIIDetecting: Sendable {
    func detections(in text: String) -> [PIIDetection]
}

/// Manifest emitted by the current PII trainer for the bundled WordPiece
/// token-classification model.
public struct PIIModelManifest: Codable, Hashable, Sendable {
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
    public let sha256: String
}

public enum PIIDetectorLoader {
    public static let defaultResourceName = "SiftPIIDetector"

    public static func manifest(
        resourceName: String = defaultResourceName,
        bundles: [Bundle] = [.main]
    ) -> PIIModelManifest? {
        for bundle in bundles {
            guard
                let url = bundle.url(forResource: "\(resourceName).manifest", withExtension: "json"),
                let data = try? Data(contentsOf: url),
                let manifest = try? JSONDecoder().decode(PIIModelManifest.self, from: data)
            else {
                continue
            }
            return manifest
        }
        return nil
    }

    public static func isAvailable(
        resourceName: String = defaultResourceName,
        bundles: [Bundle] = [.main]
    ) -> Bool {
        guard let manifest = manifest(resourceName: resourceName, bundles: bundles) else {
            return false
        }
        return vocabularyURL(for: manifest, bundles: bundles) != nil
            && modelURL(for: manifest, bundles: bundles) != nil
    }

    /// Loads the optional bundled PII model; nil (rules-only sanitization)
    /// when the artifacts are not shipped or fail to load.
    public static func bundled(
        resourceName: String = defaultResourceName,
        bundles: [Bundle] = [.main],
        confidenceThreshold: Double = 0.85
    ) -> (any PIIDetecting)? {
        #if canImport(CoreML)
        guard
            let manifest = manifest(resourceName: resourceName, bundles: bundles),
            let vocabularyURL = vocabularyURL(for: manifest, bundles: bundles),
            let modelURL = modelURL(for: manifest, bundles: bundles)
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
            return try CoreMLPIIDetector(
                modelURL: modelURL,
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

    private static func vocabularyURL(
        for manifest: PIIModelManifest,
        bundles: [Bundle]
    ) -> URL? {
        let artifact = URL(fileURLWithPath: manifest.vocabularyArtifact)
        guard
            artifact.lastPathComponent == manifest.vocabularyArtifact,
            artifact.pathExtension == "txt"
        else {
            return nil
        }
        return bundles.lazy.compactMap {
            $0.url(forResource: artifact.deletingPathExtension().lastPathComponent, withExtension: artifact.pathExtension)
        }.first
    }

    private static func modelURL(for manifest: PIIModelManifest, bundles: [Bundle]) -> URL? {
        let artifact = URL(fileURLWithPath: manifest.modelArtifact)
        guard
            artifact.lastPathComponent == manifest.modelArtifact,
            artifact.pathExtension == "mlpackage"
        else {
            return nil
        }
        return bundles.lazy.compactMap {
            $0.url(forResource: artifact.deletingPathExtension().lastPathComponent, withExtension: "mlmodelc")
        }.first
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
        confidenceThreshold: Double = 0.85
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
            let detections = mergeAdjacent(wordKinds: wordKinds, wordRanges: encoded.wordRanges)
            return PIIDetectionPostprocessor.expandingGroupedAmounts(detections, in: text)
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

    /// Average tag probability across all pieces in a word. A non-PII tag
    /// must beat the O probability and clear the confidence threshold, which
    /// prevents one noisy subword from redacting the entire word.
    private func classifyWords(
        encoded: WordPieceTokenizer.EncodedTextWithOffsets,
        logits: MLMultiArray
    ) -> [PIIKind?] {
        var wordKinds: [PIIKind?] = Array(repeating: nil, count: encoded.wordRanges.count)
        var probabilitySums = Array(
            repeating: Array(repeating: 0.0, count: tags.count),
            count: encoded.wordRanges.count
        )
        var pieceCounts = Array(repeating: 0, count: encoded.wordRanges.count)

        for position in 0..<encoded.wordIndices.count {
            guard let wordIndex = encoded.wordIndices[position] else { continue }
            let probabilities = softmaxProbabilities(logits: logits, position: position)
            for tagIndex in probabilities.indices {
                probabilitySums[wordIndex][tagIndex] += probabilities[tagIndex]
            }
            pieceCounts[wordIndex] += 1
        }

        let outsideIndex = tags.firstIndex { normalizedTag($0) == "O" }
        for wordIndex in wordKinds.indices where pieceCounts[wordIndex] > 0 {
            let divisor = Double(pieceCounts[wordIndex])
            let averages = probabilitySums[wordIndex].map { $0 / divisor }
            let outsideProbability = outsideIndex.map { averages[$0] } ?? 0
            guard let best = averages.indices
                .filter({ $0 != outsideIndex })
                .max(by: { averages[$0] < averages[$1] })
            else { continue }
            let probability = averages[best]
            guard
                probability >= confidenceThreshold,
                probability > outsideProbability,
                let kind = PIIKind(rawValue: normalizedTag(tags[best]))
            else { continue }
            wordKinds[wordIndex] = kind
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

    private func softmaxProbabilities(logits: MLMultiArray, position: Int) -> [Double] {
        let offset = position * tags.count
        var maxLogit = -Double.infinity
        var values: [Double] = []
        values.reserveCapacity(tags.count)
        for tagIndex in 0..<tags.count {
            let value = logits[offset + tagIndex].doubleValue
            values.append(value)
            if value > maxLogit {
                maxLogit = value
            }
        }
        let expSum = values.reduce(0) { $0 + exp($1 - maxLogit) }
        return values.map { exp($0 - maxLogit) / expSum }
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
