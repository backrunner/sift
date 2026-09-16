import Foundation

/// Cancellation must finish writing resume data before another task can use
/// the same staging files or background URLSession identifiers.
actor TransformerDownloadCoordinator {
    static let shared = TransformerDownloadCoordinator()
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(_ operation: @Sendable () async throws -> Void) async throws {
        if isRunning {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isRunning = true
        }
        defer {
            if waiters.isEmpty {
                isRunning = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        try Task.checkCancellation()
        try await operation()
    }
}
