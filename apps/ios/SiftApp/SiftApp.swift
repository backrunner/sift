import MessageFilterCore
import SiftAppKit
import SwiftUI
import UIKit

#if DEBUG
private struct ScreenshotRemoteSampleClient: RemoteSampleSubmitting {
    func accountStatus() async -> RemoteSampleAccountStatus { .available }

    func submit(
        sanitizedText: String,
        labelID: String,
        modelVersion: String?,
        assessment: LocalAssessment?
    ) async throws -> RemoteSampleReceipt {
        RemoteSampleReceipt(accepted: true, receiptToken: "screenshot-receipt")
    }

    func delete(receiptToken: String) async throws -> Bool { true }

    func fetchMySubmissions() async throws -> [RemoteSubmissionSummary] { [] }

    func fetchMySubmissions(before createdAtMillis: Int64?, limit: Int) async throws -> [RemoteSubmissionSummary] { [] }

    func eraseAllSubmissions() async throws -> Int { 0 }
}

private struct ScreenshotPremiumBackend: PremiumPurchasing {
    func loadProduct(identifier: String) async throws -> PremiumProductInfo? { nil }

    func purchase(identifier: String) async -> PremiumPurchaseOutcome { .cancelled }

    func isEntitled(identifier: String) async -> Bool { false }

    func restore(identifier: String) async throws -> Bool { false }

    func entitlementUpdates(identifier: String) -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
#endif

private final class SiftApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        TransformerBackgroundSessionEvents.handle(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct SiftApp: App {
    @UIApplicationDelegateAdaptor(SiftApplicationDelegate.self) private var applicationDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: SiftAppModel?

    init() {
        let isDeviceBenchmarkHost = ProcessInfo.processInfo.environment["SIFT_DEVICE_BENCHMARK_HOST"] == "1"
        guard !isDeviceBenchmarkHost else {
            _model = State(initialValue: nil)
            return
        }

        #if DEBUG
        if ProcessInfo.processInfo.environment["SIFT_SCREENSHOT_MODE"] == "1" {
            let defaults = UserDefaults(suiteName: "SiftScreenshot-\(UUID().uuidString)") ?? .standard
            let sampleURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("sift-screenshot-\(UUID().uuidString).ndjson")
            let screenshotModel = SiftAppModel(
                remoteSampleClient: ScreenshotRemoteSampleClient(),
                premiumBackend: ScreenshotPremiumBackend(),
                transformerAvailabilityOverride: false,
                transformerDownloadedOverride: false,
                transformerDeviceSupportOverride: .supported,
                appDefaults: defaults,
                sampleStore: LocalSampleStore(fileURL: sampleURL)
            )
            screenshotModel.hasConfirmedFilterSetup = true
            screenshotModel.submissionDestination = .remote
            screenshotModel.submissionText = String(localized: "您的验证码是 482913，请联系 13800138000 或访问 https://example.com/claim 完成验证。")
            screenshotModel.testBody = screenshotModel.submissionText
            _model = State(initialValue: screenshotModel)
            return
        }
        #endif

        _model = State(initialValue: SiftAppModel())
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                SiftRootView(model: model)
                    .task {
                        model.applicationDidBecomeActive()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            model.applicationDidBecomeActive()
                        }
                    }
            } else {
                Color.clear
            }
        }
    }
}
