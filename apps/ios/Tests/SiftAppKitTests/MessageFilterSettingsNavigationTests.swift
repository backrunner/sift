import Foundation
import Testing
@testable import SiftAppKit

@MainActor
@Test(arguments: [0, 1, 2, 3])
func filterSettingsNavigationFallsBackOnlyAfterRejection(rejectedCount: Int) async {
    let settingsHomeURL = URL(string: "App-prefs:")!
    var attempts: [URL] = []

    let accepted = await MessageFilterSettingsNavigation.open(settingsHomeURL: settingsHomeURL) { url in
        attempts.append(url)
        return attempts.count > rejectedCount
    }

    #expect(accepted == (rejectedCount < 3))
    #expect(attempts.count == min(rejectedCount + 1, 3))
    #expect(attempts.first?.absoluteString == "App-prefs:root=MESSAGES&path=FILTER_UNKNOWN_SENDERS")
    if attempts.count > 1 {
        #expect(attempts[1].absoluteString == "App-prefs:root=MESSAGES")
    }
    if attempts.count > 2 {
        #expect(attempts[2] == settingsHomeURL)
    }
}
