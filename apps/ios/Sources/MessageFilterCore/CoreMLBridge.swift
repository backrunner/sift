import Foundation

#if canImport(CoreML)
import CoreML
#endif

#if canImport(CreateML)
import CreateML
#endif

#if canImport(TabularData)
import TabularData
#endif

public enum LocalUpdateState: Hashable, Sendable {
    case ready
    case missingModel
    case personalized
    case unsupported
    case failed(String)
}

public struct LocalTrainingArtifact: Hashable, Sendable {
    public let state: LocalUpdateState
    public let modelURL: URL?
    public let note: String

    public init(state: LocalUpdateState, modelURL: URL?, note: String) {
        self.state = state
        self.modelURL = modelURL
        self.note = note
    }
}

public struct PersonalizationTrainer: Sendable {
    public let outputURL: URL
    public let hasher: FeatureHasher

    public init(
        outputURL: URL = LocalSampleStore.defaultFileURL(filename: "personalization.mlmodel"),
        hasher: FeatureHasher = FeatureHasher(dimension: 512)
    ) {
        self.outputURL = outputURL
        self.hasher = hasher
    }

    public func updateModel(from samples: [StoredSample], baseModelURL: URL? = nil) async -> LocalTrainingArtifact {
        guard samples.count >= 2 else {
            return LocalTrainingArtifact(
                state: .ready,
                modelURL: baseModelURL,
                note: "Collect at least two local samples before personalization."
            )
        }

        let labelIDs = Set(samples.map(\.labelID))
        guard labelIDs.count >= 2 else {
            return LocalTrainingArtifact(
                state: .ready,
                modelURL: baseModelURL,
                note: "Local personalization needs samples from at least two labels."
            )
        }

        #if canImport(CoreML) && canImport(CreateML) && canImport(TabularData)
        if #available(iOS 18.0, macOS 15.0, *) {
            do {
                let frame = try makeTrainingFrame(from: samples)
                let parameters = MLLogisticRegressionClassifier.ModelParameters(
                    validation: .none,
                    maxIterations: 80,
                    l1Penalty: 0,
                    l2Penalty: 0.01,
                    stepSize: 1,
                    convergenceThreshold: 0.01,
                    featureRescaling: true
                )
                let classifier = try MLLogisticRegressionClassifier(
                    trainingData: frame,
                    targetColumn: "label",
                    featureColumns: featureColumnNames,
                    parameters: parameters
                )

                let compiledURL = try writeAndCompile(classifier: classifier)

                return LocalTrainingArtifact(
                    state: .personalized,
                    modelURL: compiledURL,
                    note: "Personalized adapter trained with \(samples.count) local samples across \(labelIDs.count) labels."
                )
            } catch {
                return LocalTrainingArtifact(
                    state: .failed(String(describing: error)),
                    modelURL: baseModelURL,
                    note: "Create ML Components personalization failed."
                )
            }
        } else {
            return LocalTrainingArtifact(
                state: .unsupported,
                modelURL: baseModelURL,
                note: "On-device personalization requires iOS 18 / macOS 15 in this build."
            )
        }
        #else
        return LocalTrainingArtifact(
            state: .unsupported,
            modelURL: baseModelURL,
            note: "Create ML is unavailable in this build environment."
        )
        #endif
    }

    private var featureColumnNames: [String] {
        (0..<hasher.dimension).map { "f\($0)" }
    }

    #if canImport(CoreML) && canImport(CreateML) && canImport(TabularData)
    private func makeTrainingFrame(from samples: [StoredSample]) throws -> DataFrame {
        var columns: [AnyColumn] = [
            Column(name: "label", contents: samples.map(\.labelID)).eraseToAnyColumn()
        ]

        var featureColumns = Array(repeating: [Double](), count: hasher.dimension)
        featureColumns.indices.forEach { index in
            featureColumns[index].reserveCapacity(samples.count)
        }

        for sample in samples {
            let vector = hasher.denseVector(sender: sample.sender, body: sample.body)
            for index in 0..<hasher.dimension {
                featureColumns[index].append(Double(vector[index]))
            }
        }

        for (index, values) in featureColumns.enumerated() {
            columns.append(Column(name: "f\(index)", contents: values).eraseToAnyColumn())
        }

        return DataFrame(columns: columns)
    }

    private func writeAndCompile(classifier: MLLogisticRegressionClassifier) throws -> URL {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let metadata = MLModelMetadata(
            author: "Sift",
            shortDescription: "Local privacy-preserving SMS personalization adapter.",
            license: "Apache-2.0",
            version: "personal"
        )
        try classifier.write(to: outputURL, metadata: metadata)

        let compiledTemporaryURL = try MLModel.compileModel(at: outputURL)
        let compiledURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension("mlmodelc")
        if FileManager.default.fileExists(atPath: compiledURL.path) {
            try FileManager.default.removeItem(at: compiledURL)
        }
        try FileManager.default.moveItem(at: compiledTemporaryURL, to: compiledURL)
        return compiledURL
    }
    #endif
}
