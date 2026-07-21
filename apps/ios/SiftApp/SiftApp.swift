import SiftAppKit
import SwiftUI
import UIKit

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
        _model = State(initialValue: isDeviceBenchmarkHost ? nil : SiftAppModel())
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
