import Foundation

/// Delivers the first completion value and ignores every later attempt.
///
/// IdentityLookup handlers race normal classification against a watchdog, so
/// the gate must remain correct when both paths finish concurrently.
public final class CompletionOnceGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Value) -> Void)?

    public init(completion: @escaping (Value) -> Void) {
        self.completion = completion
    }

    @discardableResult
    public func complete(_ value: Value) -> Bool {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()

        guard let completion else {
            return false
        }
        completion(value)
        return true
    }
}
