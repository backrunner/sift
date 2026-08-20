import Foundation

struct DeveloperModeTapCounter: Sendable {
    static let requiredTapCount = 7
    static let maximumIntervalBetweenTaps: TimeInterval = 2

    private var tapCount = 0
    private var lastTapAt: Date?

    mutating func registerTap(at date: Date) -> Bool {
        if
            let lastTapAt,
            date >= lastTapAt,
            date.timeIntervalSince(lastTapAt) <= Self.maximumIntervalBetweenTaps
        {
            tapCount += 1
        } else {
            tapCount = 1
        }
        self.lastTapAt = date

        guard tapCount >= Self.requiredTapCount else {
            return false
        }
        tapCount = 0
        lastTapAt = nil
        return true
    }
}
