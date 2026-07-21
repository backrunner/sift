import Foundation
#if os(iOS)
import Darwin
#endif

/// Hardware gate for the Premium Transformer. MessageFilter runs in a tight
/// extension budget, so pre-A12 devices use Classic rather than attempting a
/// graph load that cannot meet the latency and memory gates.
public struct TransformerDeviceSupport: Equatable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case supported
        case unsupported
    }

    public enum Reason: String, Codable, Sendable {
        case belowMinimumNeuralEngine
        case simulator
        case unknownHardware
    }

    public let status: Status
    public let reason: Reason?

    public var isSupported: Bool { status == .supported }

    public static let supported = TransformerDeviceSupport(status: .supported, reason: nil)

    public init(status: Status, reason: Reason?) {
        self.status = status
        self.reason = reason
    }

    public static func current() -> TransformerDeviceSupport {
        #if os(iOS)
        #if targetEnvironment(simulator)
        return TransformerDeviceSupport(status: .unsupported, reason: .simulator)
        #else
        return evaluate(hardwareIdentifier: hardwareIdentifier())
        #endif
        #else
        // The Swift package's macOS test host has no iPhone SoC to inspect.
        // Production iOS builds always take the hardware path above.
        return .supported
        #endif
    }

    public static func evaluate(hardwareIdentifier: String) -> TransformerDeviceSupport {
        if hardwareIdentifier.hasPrefix("iPhone") {
            return evaluateDeviceFamily(identifier: hardwareIdentifier, minimumFamily: 11)
        }
        if hardwareIdentifier.hasPrefix("iPad") {
            return evaluateDeviceFamily(identifier: hardwareIdentifier, minimumFamily: 8)
        }
        if hardwareIdentifier.hasPrefix("iPod") {
            return TransformerDeviceSupport(status: .unsupported, reason: .belowMinimumNeuralEngine)
        }
        return TransformerDeviceSupport(status: .unsupported, reason: .unknownHardware)
    }

    private static func evaluateDeviceFamily(
        identifier: String,
        minimumFamily: Int
    ) -> TransformerDeviceSupport {
        let familyDigits = identifier.drop { !$0.isNumber }
        let family = Int(familyDigits.prefix { $0.isNumber })
        guard let family else {
            return TransformerDeviceSupport(status: .unsupported, reason: .unknownHardware)
        }
        return family >= minimumFamily
            ? .supported
            : TransformerDeviceSupport(status: .unsupported, reason: .belowMinimumNeuralEngine)
    }

    #if os(iOS)
    private static func hardwareIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }
        var machine = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else {
            return ""
        }
        let bytes = machine.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
    #endif
}
