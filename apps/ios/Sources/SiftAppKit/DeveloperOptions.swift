import Foundation
import MessageFilterCore
import StoreKit

/// Developer options exist only outside the App Store, so a customer can never reach a
/// dev model and the shipped app keeps no hidden feature. Unknown means not eligible.
public protocol DeveloperOptionsEligibilityChecking: Sendable {
    func isEligible() async -> Bool
}

public struct AppTransactionDeveloperOptionsEligibility: DeveloperOptionsEligibilityChecking {
    public init() {}

    public func isEligible() async -> Bool {
        #if DEBUG
        return true
        #else
        guard case let .verified(transaction) = try? await AppTransaction.shared else { return false }
        return transaction.environment != .production
        #endif
    }
}

public struct DeveloperOptionsRevealCounter: Sendable {
    public static let requiredTaps = 7
    public static let maximumGap: TimeInterval = 2

    private var taps = 0
    private var lastTap: Date?

    public init() {}

    /// Returns true on the tap that completes the sequence; a pause starts over.
    public mutating func register(at date: Date) -> Bool {
        if let lastTap, date.timeIntervalSince(lastTap) > Self.maximumGap { taps = 0 }
        lastTap = date
        taps += 1
        guard taps >= Self.requiredTaps else { return false }
        taps = 0
        return true
    }
}

extension SignalModelTrack {
    var localizedTitle: String {
        switch self {
        case .stable: return String(localized: "正式版")
        case .beta: return String(localized: "测试版")
        case .dev: return String(localized: "开发版")
        }
    }
}
