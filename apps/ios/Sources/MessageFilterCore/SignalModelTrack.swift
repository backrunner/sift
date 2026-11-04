import Foundation

/// Publishing track of a Signal release. A signed field, so a dev release can never
/// be replayed through the stable pointer. Absent means stable for older releases.
public enum SignalModelTrack: String, Codable, CaseIterable, Hashable, Sendable {
    case stable, beta, dev

    public init(signedValue: String?) {
        self = signedValue.flatMap(Self.init(rawValue:)) ?? .stable
    }

    /// Value written into a signed payload; stable stays absent so existing
    /// signatures keep verifying byte for byte.
    public var signedValue: String? {
        self == .stable ? nil : rawValue
    }

    public func channelNamespace(base: String) -> String {
        self == .stable ? base : "\(base)/\(rawValue)"
    }

    /// Non-stable pointers sit beside the stable one:
    /// `channels/v3/SiftSignalModel.channel.json` -> `channels/v3/dev/SiftSignalModel.channel.json`.
    public func channelURL(fromStable stableURL: URL) -> URL {
        guard self != .stable else { return stableURL }
        let file = stableURL.lastPathComponent
        return stableURL.deletingLastPathComponent()
            .appendingPathComponent(rawValue, isDirectory: true)
            .appendingPathComponent(file, isDirectory: false)
    }
}
