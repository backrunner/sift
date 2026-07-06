import Foundation

#if canImport(CoreML)
import CoreML
#endif

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public enum AppleClassifierLoader {
    public static func bundled(
        resourceName: String = "SiftSMSClassifier",
        bundles: [Bundle] = [.main],
        confidenceThreshold: Double = 0.62
    ) -> (any MessageClassifier)? {
        #if canImport(NaturalLanguage)
        for bundle in bundles {
            if
                let modelURL = bundle.url(forResource: resourceName, withExtension: "mlmodelc"),
                let classifier = try? NLModelTextClassifier(modelURL: modelURL, confidenceThreshold: confidenceThreshold)
            {
                return classifier
            }

            #if canImport(CoreML)
            if
                let sourceModelURL = bundle.url(forResource: resourceName, withExtension: "mlmodel"),
                let compiledURL = try? MLModel.compileModel(at: sourceModelURL),
                let classifier = try? NLModelTextClassifier(modelURL: compiledURL, confidenceThreshold: confidenceThreshold)
            {
                return classifier
            }
            #endif
        }
        return nil
        #else
        return nil
        #endif
    }

    public static func personalized(
        modelURL: URL,
        hasher: FeatureHasher = FeatureHasher(dimension: 512),
        confidenceThreshold: Double = 0.7
    ) -> (any MessageClassifier)? {
        #if canImport(CoreML)
        return try? CoreMLFeatureVectorClassifier(
            modelURL: modelURL,
            hasher: hasher,
            confidenceThreshold: confidenceThreshold
        )
        #else
        return nil
        #endif
    }

    public static func defaultClassifier() -> any MessageClassifier {
        if let bundled = bundled() {
            return CascadingClassifier(
                primary: bundled,
                fallback: HeuristicClassifier(),
                primaryThreshold: 0.6
            )
        }

        return HeuristicClassifier()
    }

    /// Builds the classifier stack for the selected model variant. Falls back
    /// to the classic stack when transformer artifacts are not installed.
    public static func classifier(
        for variant: ModelVariant,
        bundles: [Bundle] = [.main]
    ) -> any MessageClassifier {
        switch variant {
        case .classic:
            return defaultClassifier()
        case .transformer:
            guard let transformer = TransformerClassifierLoader.available(bundles: bundles) else {
                return defaultClassifier()
            }
            return CascadingClassifier(
                primary: transformer,
                fallback: HeuristicClassifier(),
                primaryThreshold: 0.5
            )
        }
    }
}

#if canImport(NaturalLanguage)
public final class NLModelTextClassifier: MessageClassifier, @unchecked Sendable {
    private let model: NLModel
    private let confidenceThreshold: Double

    public init(modelURL: URL, confidenceThreshold: Double = 0.62) throws {
        self.model = try NLModel(contentsOf: modelURL)
        self.confidenceThreshold = confidenceThreshold
    }

    public func classify(sender: String?, body: String) -> ClassificationDecision {
        let hypotheses = model.predictedLabelHypotheses(for: body, maximumCount: 3)
        let best = hypotheses.max { lhs, rhs in
            lhs.value < rhs.value
        }

        if let best {
            guard
                let leaf = SiftTaxonomy.leaf(id: best.key),
                best.value >= confidenceThreshold
            else {
                return fallbackDecision(confidence: best.value)
            }

            return decision(for: leaf, confidence: best.value)
        }

        if
            let predicted = model.predictedLabel(for: body),
            let leaf = SiftTaxonomy.leaf(id: predicted)
        {
            return decision(for: leaf, confidence: confidenceThreshold)
        }

        return fallbackDecision(confidence: 0)
    }

    private func decision(for leaf: LeafLabel, confidence: Double) -> ClassificationDecision {
        ClassificationDecision(
            labelID: leaf.id,
            labelTitle: leaf.title,
            groupID: leaf.groupId,
            groupTitle: leaf.groupTitle,
            confidence: confidence,
            systemAction: leaf.systemAction,
            source: .model
        )
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

#if canImport(CoreML)
public final class CoreMLFeatureVectorClassifier: MessageClassifier, @unchecked Sendable {
    private let model: MLModel
    private let hasher: FeatureHasher
    private let confidenceThreshold: Double

    public init(
        modelURL: URL,
        hasher: FeatureHasher = FeatureHasher(dimension: 512),
        confidenceThreshold: Double = 0.7
    ) throws {
        self.model = try MLModel(contentsOf: modelURL)
        self.hasher = hasher
        self.confidenceThreshold = confidenceThreshold
    }

    public func classify(sender: String?, body: String) -> ClassificationDecision {
        do {
            let vector = hasher.denseVector(sender: sender, body: body)
            var features: [String: MLFeatureValue] = [:]
            features.reserveCapacity(vector.count)
            for (index, value) in vector.enumerated() {
                features["f\(index)"] = MLFeatureValue(double: Double(value))
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: features)
            let output = try model.prediction(from: provider)
            let predictedName = model.modelDescription.predictedFeatureName ?? "label"
            let probabilityName = model.modelDescription.predictedProbabilitiesName

            guard
                let labelID = output.featureValue(for: predictedName)?.stringValue,
                let leaf = SiftTaxonomy.leaf(id: labelID)
            else {
                return fallbackDecision(confidence: 0)
            }

            let confidence = confidence(
                for: labelID,
                probabilityFeature: probabilityName.flatMap { output.featureValue(for: $0) }
            )

            guard confidence >= confidenceThreshold else {
                return fallbackDecision(confidence: confidence)
            }

            return ClassificationDecision(
                labelID: leaf.id,
                labelTitle: leaf.title,
                groupID: leaf.groupId,
                groupTitle: leaf.groupTitle,
                confidence: confidence,
                systemAction: leaf.systemAction,
                source: .personalization
            )
        } catch {
            return fallbackDecision(confidence: 0)
        }
    }

    private func confidence(for labelID: String, probabilityFeature: MLFeatureValue?) -> Double {
        guard let dictionary = probabilityFeature?.dictionaryValue else {
            return confidenceThreshold
        }

        if let value = dictionary[AnyHashable(labelID)] {
            return value.doubleValue
        }
        if let value = dictionary[AnyHashable(labelID as NSString)] {
            return value.doubleValue
        }
        return confidenceThreshold
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
