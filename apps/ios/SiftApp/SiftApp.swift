import SiftAppKit
import SwiftUI

@main
struct SiftApp: App {
    @State private var model = SiftAppModel()

    var body: some Scene {
        WindowGroup {
            SiftRootView(model: model)
        }
    }
}
