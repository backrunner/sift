import Foundation
import Testing
@testable import MessageFilterCore

@Suite struct SignalModelTrackTests {
    private let stable = URL(string: "https://sift.alkinum.com/models/channels/v3/SiftSignalModel.channel.json")!

    @Test func nonStablePointersSitBesideStable() {
        #expect(SignalModelTrack.stable.channelURL(fromStable: stable) == stable)
        #expect(SignalModelTrack.beta.channelURL(fromStable: stable).path == "/models/channels/v3/beta/SiftSignalModel.channel.json")
        #expect(SignalModelTrack.dev.channelURL(fromStable: stable).path == "/models/channels/v3/dev/SiftSignalModel.channel.json")
        #expect(SignalModelTrack.dev.channelNamespace(base: "v3") == "v3/dev")
    }

    @Test func absentOrUnknownTrackIsStable() {
        #expect(SignalModelTrack(signedValue: nil) == .stable)
        #expect(SignalModelTrack(signedValue: "nightly") == .stable)
        #expect(SignalModelTrack.stable.signedValue == nil)
        #expect(SignalModelTrack.dev.signedValue == "dev")
    }

    private func channel(track: String?) -> TransformerChannelManifestV2 {
        TransformerChannelManifestV2(releaseSequence: 7, releaseID: "r", releaseManifestURL: "https://x/r",
            releaseManifestSHA256: "a", modelABI: "sift-signal-v1", minimumAppBuild: 34, maximumAppBuild: 40,
            minimumOSVersion: "18.0", keyID: "k", track: track)
    }

    @Test func stablePayloadIsUnchangedAndTrackIsSigned() throws {
        let stablePayload = try #require(String(data: channel(track: nil).canonicalPayload(), encoding: .utf8))
        #expect(!stablePayload.contains("track"))
        #expect(channel(track: "dev").canonicalPayload() != channel(track: nil).canonicalPayload())
        #expect(channel(track: "dev").releaseEntry.track == "dev")
    }
}

@Suite struct RoutedReleaseContractTests {
    private struct Fixture: Decodable {
        let publicKeyBase64: String
        let channel: TransformerChannelManifestV2
        let release: TransformerModelManifest
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("tools/transformer-trainer/tests/fixtures/manifest_v2_track_ed25519.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func pythonSignedTrackAndRoutingVerifyInSwift() throws {
        let fixture = try fixture()
        let verifier = TransformerManifestVerifier(publicKeys: [fixture.channel.keyID: fixture.publicKeyBase64])
        try verifier.verifySignature(of: fixture.channel)
        try verifier.verifySignature(of: fixture.release)
        #expect(fixture.channel.resolvedTrack == .dev)
        #expect(fixture.release.track == .dev)
        #expect(fixture.release.routing != nil)
    }

    @Test func replayingADevEntryAsStableBreaksItsSignature() throws {
        let channel = try fixture()
        let c = channel.channel
        let stripped = TransformerChannelManifestV2(releaseSequence: c.releaseSequence, releaseID: c.releaseID,
            releaseManifestURL: c.releaseManifestURL, releaseManifestSHA256: c.releaseManifestSHA256, modelABI: c.modelABI,
            minimumAppBuild: c.minimumAppBuild, maximumAppBuild: c.maximumAppBuild, minimumOSVersion: c.minimumOSVersion,
            downloadBytes: c.downloadBytes, keyID: c.keyID, signature: c.signature)
        let verifier = TransformerManifestVerifier(publicKeys: [c.keyID: channel.publicKeyBase64])
        #expect(throws: (any Error).self) { try verifier.verifySignature(of: stripped) }
    }
}

@Suite struct TransformerRoutingGateTests {
    private static func labels() -> [String] { SiftTaxonomy.leaves.map(\.id) + [ModelOutputContract.abstainLabel] }

    private static func distribution(top: String, share: Double = 0.9) -> [String: Double] {
        let all = labels()
        return Dictionary(uniqueKeysWithValues: all.map { ($0, $0 == top ? share : (1 - share) / Double(all.count - 1)) })
    }

    private static func profile(_ value: (Int) -> Float) -> TransformerRoutingProfile {
        var data = Data()
        for index in 0..<57 {
            var bits = value(index).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return TransformerRoutingProfile(kind: TransformerRoutingProfile.directionalKind, gateWeights: data.base64EncodedString())
    }

    @Test func rejectsWrongKindSizeAndNonFiniteWeights() {
        #expect(TransformerRoutingGate(profile: TransformerRoutingProfile(kind: "other", gateWeights: Self.profile { _ in 0 }.gateWeights)) == nil)
        #expect(TransformerRoutingGate(profile: TransformerRoutingProfile(kind: TransformerRoutingProfile.directionalKind, gateWeights: "AAAA")) == nil)
        #expect(TransformerRoutingGate(profile: Self.profile { _ in .nan }) == nil)
        #expect(TransformerRoutingGate(profile: Self.profile { _ in 0 }) != nil)
    }

    @Test func featuresMatchTrainingDefinition() throws {
        let fine = Self.distribution(top: "spam")
        let head = ["business": 0.1, "ordinary": 0.1, "commercial": 0.1, "harmful": 0.7]
        let features = try #require(TransformerRoutingGate.features(fineProbabilities: fine, actionProbabilities: head))
        #expect(features.count == TransformerRoutingGate.featureCount)
        #expect(abs(features[3] - Float(fine["spam"]! + fine.filter { $0.key != "spam" && SiftTaxonomy.leaf(id: $0.key)?.systemAction == .junk }.values.reduce(0, +))) < 1e-5)
        #expect(abs(features[7] - 0.7) < 1e-6)
        #expect(features[8] > 0.89)
        #expect(features[13] == 0, "fine and head agree on junk")
        #expect(Array(features[14...]) == [0, 0, 0, 1])
    }

    @Test func gateFollowsItsBiasToChooseBetweenFineAndHead() throws {
        let fine = Self.distribution(top: "life.express")
        let head = ["business": 0.05, "ordinary": 0.05, "commercial": 0.05, "harmful": 0.85]
        let closed = try #require(TransformerRoutingGate(profile: Self.profile { $0 >= 54 ? -9 : 0 }))
        let open = try #require(TransformerRoutingGate(profile: Self.profile { $0 >= 54 ? 9 : 0 }))
        #expect(closed.decision(fineProbabilities: fine, actionProbabilities: head)?.labelID == "life.express")
        #expect(open.decision(fineProbabilities: fine, actionProbabilities: head)?.systemAction == .junk)
    }

    @Test func invalidHeadIsRejected() {
        let gate = TransformerRoutingGate(profile: Self.profile { _ in 0 })!
        #expect(gate.decision(fineProbabilities: Self.distribution(top: "spam"), actionProbabilities: ["business": 1]) == nil)
    }
}
