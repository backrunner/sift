#if canImport(Testing)
import Foundation
import MessageFilterCore
@testable import SiftAppKit
import Testing

@Test
func developerModePersistsInAnIsolatedSharedDefaultsSuite() throws {
    let suiteName = "SiftTests.developerMode.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(DeveloperModeStore.isEnabled(defaults: defaults) == false)
    #expect(DeveloperModeStore.enable(defaults: defaults))
    #expect(DeveloperModeStore.isEnabled(defaults: defaults))
    #expect(DeveloperModeStore.enable(defaults: defaults) == false)
}

@Test
func developerModeTapCounterUnlocksAfterSevenRapidTaps() {
    var counter = DeveloperModeTapCounter()
    let start = Date(timeIntervalSince1970: 1_000)

    for index in 0..<(DeveloperModeTapCounter.requiredTapCount - 1) {
        let didUnlock = counter.registerTap(
            at: start.addingTimeInterval(Double(index) * 0.2)
        )
        #expect(didUnlock == false)
    }
    let didUnlock = counter.registerTap(at: start.addingTimeInterval(1.2))
    #expect(didUnlock)
}

@Test
func developerModeTapCounterResetsAfterAPause() {
    var counter = DeveloperModeTapCounter()
    let start = Date(timeIntervalSince1970: 1_000)

    for index in 0..<(DeveloperModeTapCounter.requiredTapCount - 1) {
        let didUnlock = counter.registerTap(
            at: start.addingTimeInterval(Double(index) * 0.2)
        )
        #expect(didUnlock == false)
    }
    let didUnlock = counter.registerTap(
        at: start.addingTimeInterval(DeveloperModeTapCounter.maximumIntervalBetweenTaps + 2)
    )
    #expect(didUnlock == false)
}
#endif
