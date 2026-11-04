#if canImport(Testing)
import Foundation
import MessageFilterCore
@testable import SiftAppKit
import Testing

private struct FixedEligibility: DeveloperOptionsEligibilityChecking {
    let value: Bool
    func isEligible() async -> Bool { value }
}

private final class TrackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SignalModelTrack] = []
    func append(_ track: SignalModelTrack) { lock.withLock { values.append(track) } }
    var tracks: [SignalModelTrack] { lock.withLock { values } }
}

@MainActor
private func makeModel(eligible: Bool, defaults: UserDefaults, recorder: TrackRecorder = TrackRecorder()) -> SiftAppModel {
    SiftAppModel(
        transformerDownloader: nil,
        developerOptionsEligibility: FixedEligibility(value: eligible),
        transformerDownloaderForTrack: { recorder.append($0); return nil },
        appDefaults: defaults
    )
}

@MainActor
private func tapVersion(_ model: SiftAppModel, times: Int, start: Date = Date(), gap: TimeInterval = 0.2) {
    for index in 0..<times { model.registerVersionTap(at: start.addingTimeInterval(Double(index) * gap)) }
}

@MainActor
private func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
    let suite = "SiftTests.developerOptions.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try await body(defaults)
}

@Test
func revealCounterNeedsSevenQuickTapsAndAPauseStartsOver() {
    let start = Date()
    var counter = DeveloperOptionsRevealCounter()
    let quick = (0..<7).map { counter.register(at: start.addingTimeInterval(Double($0))) }
    #expect(quick == [false, false, false, false, false, false, true])
    var paused = DeveloperOptionsRevealCounter()
    let interrupted = [0.0, 1, 2, 3, 4, 5, 9].map { paused.register(at: start.addingTimeInterval($0)) }
    #expect(!interrupted.contains(true))
}

@MainActor
@Test
func productionInstallNeverRevealsOrKeepsAStoredTrack() async throws {
    try await withDefaults { defaults in
        defaults.set(true, forKey: "Sift.developerOptionsRevealed.v1")
        defaults.set("dev", forKey: "Sift.modelTrack.v1")
        let recorder = TrackRecorder()
        let model = makeModel(eligible: false, defaults: defaults, recorder: recorder)
        await model.refreshDeveloperOptionsEligibility()
        tapVersion(model, times: 10)
        model.selectModelTrack(.dev)
        #expect(!model.isDeveloperOptionsRevealed)
        #expect(model.selectedModelTrack == .stable)
        #expect(recorder.tracks.isEmpty)
    }
}

@MainActor
@Test
func eligibleInstallRevealsThenSwitchesAndPersistsTrack() async throws {
    try await withDefaults { defaults in
        let recorder = TrackRecorder()
        let model = makeModel(eligible: true, defaults: defaults, recorder: recorder)
        await model.refreshDeveloperOptionsEligibility()
        model.selectModelTrack(.dev)
        #expect(model.selectedModelTrack == .stable, "hidden options cannot change the track")
        tapVersion(model, times: 7)
        #expect(model.isDeveloperOptionsRevealed)
        model.selectModelTrack(.dev)
        #expect(model.selectedModelTrack == .dev)
        #expect(recorder.tracks == [.dev])

        let reloaded = makeModel(eligible: true, defaults: defaults, recorder: recorder)
        #expect(reloaded.selectedModelTrack == .stable, "stable until eligibility is confirmed")
        await reloaded.refreshDeveloperOptionsEligibility()
        #expect(reloaded.selectedModelTrack == .dev)
        #expect(reloaded.isDeveloperOptionsRevealed)
    }
}

@MainActor
@Test
func hidingOptionsReturnsToStableAndClearsStoredChoice() async throws {
    try await withDefaults { defaults in
        let recorder = TrackRecorder()
        let model = makeModel(eligible: true, defaults: defaults, recorder: recorder)
        await model.refreshDeveloperOptionsEligibility()
        tapVersion(model, times: 7)
        model.selectModelTrack(.beta)
        model.hideDeveloperOptions()
        #expect(!model.isDeveloperOptionsRevealed)
        #expect(model.selectedModelTrack == .stable)
        #expect(recorder.tracks == [.beta, .stable])
        #expect(defaults.string(forKey: "Sift.modelTrack.v1") == nil)
    }
}

private func release(sequence: Int, track: String?) -> TransformerChannelManifestV2 {
    TransformerChannelManifestV2(releaseSequence: sequence, releaseID: "r\(sequence)", releaseManifestURL: "https://x/r",
        releaseManifestSHA256: "a", modelABI: "sift-signal-v1", minimumAppBuild: 1, maximumAppBuild: 99,
        minimumOSVersion: "18.0", keyID: "k", track: track)
}

@Test
func clientKeepsTracksApartAndAllowsReturningToStable() throws {
    let client = TransformerModelDownloadClient(
        channelURL: URL(string: "https://example.invalid/channels/v3/dev/SiftSignalModel.channel.json")!,
        publicKeys: ["k": "EWT4wUWJG73N72DqkoNZ8MoDZYlYWPN7YrkL6QgjQKY="], appBuild: 40)
    let releases = [release(sequence: 6, track: nil), release(sequence: 7, track: "dev"), release(sequence: 8, track: "beta")]
    #expect(client.selectableReleases(in: releases).map(\.releaseSequence) == [6], "default client is stable")

    client.configureTrack(.dev, installedTrack: { .stable })
    #expect(client.selectableReleases(in: releases).map(\.releaseSequence) == [7])
    #expect(client.trackAwareSequence(6) == 0, "a release from another track is not a rollback floor")

    client.configureTrack(.stable, installedTrack: { .dev })
    #expect(client.trackAwareSequence(7) == 0, "a dev model must not block returning to stable")

    client.configureTrack(.stable, installedTrack: { .stable })
    #expect(client.trackAwareSequence(6) == 6, "rollback protection stays within a track")
}
#endif
