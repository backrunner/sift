import Foundation

/// Signed routing weights carried by a release. Base64 keeps the signed payload
/// byte-identical between the Python publisher and Swift, unlike JSON numbers.
public struct TransformerRoutingProfile: Codable, Hashable, Sendable {
    public static let directionalKind = "directional-v75"

    public let kind: String
    public let gateWeights: String

    public init(kind: String, gateWeights: String) {
        self.kind = kind
        self.gateWeights = gateWeights
    }
}

/// Directional gate over the fine and action distributions. Features match
/// `expert_routing_v71.features`, so training and the device agree on one definition.
public struct TransformerRoutingGate: Sendable {
    public static let featureCount = 18
    public static let actionHeadOrder = ["business", "ordinary", "commercial", "harmful"]
    private static let branches = TransformerDirectionalRouting.Branch.allCases.map(\.rawValue)
    private static let coarseActions: [SystemAction] = [.transaction, .none, .promotion, .junk]

    private let weights: [[Float]]
    private let biases: [Float]

    public init?(profile: TransformerRoutingProfile) {
        let outputs = Self.branches.count
        let count = outputs * Self.featureCount + outputs
        guard profile.kind == TransformerRoutingProfile.directionalKind,
              let data = Data(base64Encoded: profile.gateWeights),
              data.count == count * MemoryLayout<Float32>.size else { return nil }
        let values: [Float] = data.withUnsafeBytes { raw in
            (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        guard values.allSatisfy(\.isFinite) else { return nil }
        self.weights = (0..<outputs).map { row in
            Array(values[(row * Self.featureCount)..<((row + 1) * Self.featureCount)])
        }
        self.biases = Array(values[(outputs * Self.featureCount)...])
    }

    public func preferences(fineProbabilities: [String: Double], actionProbabilities: [String: Double]) -> [String: Double]? {
        guard let features = Self.features(fineProbabilities: fineProbabilities, actionProbabilities: actionProbabilities) else {
            return nil
        }
        var result: [String: Double] = [:]
        for (index, branch) in Self.branches.enumerated() {
            let logit = zip(weights[index], features).reduce(biases[index]) { $0 + $1.0 * $1.1 }
            result[branch] = 1 / (1 + exp(-Double(logit)))
        }
        return result
    }

    public func decision(fineProbabilities: [String: Double], actionProbabilities: [String: Double]) -> ClassificationDecision? {
        guard let preferences = preferences(fineProbabilities: fineProbabilities, actionProbabilities: actionProbabilities) else {
            return nil
        }
        return TransformerDirectionalRouting.decision(fineProbabilities: fineProbabilities,
            actionProbabilities: actionProbabilities, preferences: preferences)
    }

    static func features(fineProbabilities: [String: Double], actionProbabilities: [String: Double]) -> [Float]? {
        guard Set(actionProbabilities.keys) == Set(actionHeadOrder), fineProbabilities.count >= 2 else { return nil }
        let labels = fineProbabilities.keys.sorted()
        let fineTotal = labels.reduce(0.0) { $0 + fineProbabilities[$1]! }
        let head = actionHeadOrder.map { actionProbabilities[$0]! }
        let headTotal = head.reduce(0, +)
        guard fineTotal > 0, headTotal > 0, fineProbabilities.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              head.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let fine = labels.map { fineProbabilities[$0]! / fineTotal }
        let normalizedHead = head.map { $0 / headTotal }
        let actionIndex = labels.map { label -> Int in
            let action = SiftTaxonomy.leaf(id: label)?.systemAction ?? .none
            return coarseActions.firstIndex(of: action) ?? 1
        }
        var coarse = [Double](repeating: 0, count: 4)
        for (value, index) in zip(fine, actionIndex) { coarse[index] += value }
        let fineSorted = fine.sorted(by: >)
        let headSorted = normalizedHead.sorted(by: >)
        let fineClass = actionIndex[fine.firstIndex(of: fineSorted[0])!]
        let headClass = normalizedHead.firstIndex(of: headSorted[0])!
        let fineEntropy = -fine.reduce(0) { $0 + $1 * log(max($1, 1e-12)) } / log(Double(labels.count))
        let headEntropy = -normalizedHead.reduce(0) { $0 + $1 * log(max($1, 1e-12)) } / log(4)
        var features = coarse + normalizedHead
        features += [fineSorted[0], fineSorted[0] - fineSorted[1], fineEntropy, headSorted[0] - headSorted[1],
                     headEntropy, fineClass == headClass ? 0 : 1]
        features += (0..<4).map { $0 == fineClass ? 1 : 0 }
        return features.map { Float($0) }
    }
}
