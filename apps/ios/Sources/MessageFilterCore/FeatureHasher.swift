import Foundation

public struct HashedFeature: Hashable, Sendable {
    public let index: Int
    public let value: Double

    public init(index: Int, value: Double) {
        self.index = index
        self.value = value
    }
}

public struct FeatureHasher: Sendable {
    public let dimension: Int
    public let ngramRange: ClosedRange<Int>

    public init(dimension: Int = 2048, ngramRange: ClosedRange<Int> = 2...4) {
        self.dimension = dimension
        self.ngramRange = ngramRange
    }

    public func features(sender: String?, body: String) -> [HashedFeature] {
        var counts: [Int: Double] = [:]
        let normalizedBody = body.lowercased()
        let combined = [sender?.lowercased() ?? "", normalizedBody].joined(separator: " ")

        if combined.isEmpty {
            return []
        }

        for length in ngramRange {
            guard combined.count >= length else { continue }
            let chars = Array(combined)
            for index in 0...(chars.count - length) {
                let token = String(chars[index..<(index + length)])
                let bucket = hash(token)
                counts[bucket, default: 0] += 1
            }
        }

        if normalizedBody.contains("验证码") {
            counts[hash("feature:verification")] = 1
        }
        if normalizedBody.contains("退款") {
            counts[hash("feature:refund")] = 1
        }
        if normalizedBody.contains("快递") || normalizedBody.contains("物流") {
            counts[hash("feature:logistics")] = 1
        }

        return counts
            .sorted { $0.key < $1.key }
            .map { HashedFeature(index: $0.key, value: $0.value) }
    }

    public func denseVector(sender: String?, body: String) -> [Float] {
        var values = Array(repeating: Float(0), count: dimension)
        for feature in features(sender: sender, body: body) {
            values[feature.index] = Float(feature.value)
        }

        let squaredNorm = values.reduce(Float(0)) { partial, value in
            partial + value * value
        }
        guard squaredNorm > 0 else {
            return values
        }

        let norm = sqrt(squaredNorm)
        return values.map { $0 / norm }
    }

    private func hash(_ token: String) -> Int {
        var value: UInt64 = 1469598103934665603
        for byte in token.utf8 {
            value ^= UInt64(byte)
            value &*= 1099511628211
        }
        return Int(value % UInt64(dimension))
    }
}
