import Foundation
import MessageFilterCore

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    return true
}

func customRuleBeatsClassifier() {
    let rule = CustomRule(
        name: "VIP sender",
        priority: 100,
        sender: SenderMatcher(kind: .exact, pattern: "95588"),
        action: .allow
    )
    let pipeline = ClassificationPipeline()

    let decision = pipeline.classify(
        sender: "95588",
        body: "验证码 123456，请勿泄露。",
        rules: [rule]
    )

    expect(decision.source == .rule, "custom rule should beat classifier")
    expect(decision.labelID == "transaction.message", "allow rule should use the neutral message label")
    expect(decision.systemAction == .none, "allow rule should bypass filtering")
}

func higherPriorityRuleWins() {
    let lower = CustomRule(
        name: "promotion",
        priority: 10,
        text: TextMatcher(kind: .keyword, pattern: "取件码"),
        action: .block
    )
    let higher = CustomRule(
        name: "pickup",
        priority: 20,
        text: TextMatcher(kind: .keyword, pattern: "取件码"),
        action: .allow
    )

    let match = RuleEngine().match(sender: nil, body: "您的取件码 123456", rules: [lower, higher])

    expect(match?.rule.action == .allow, "higher priority rule should win")
}

func sanitizerRemovesObviousSensitiveTokens() {
    let sanitizer = PrivacySanitizer()
    let result = sanitizer.sanitize("请联系 13800138000，验证码 843920，金额 ¥128.50，访问 https://example.com")

    expect(result.text.contains("{{PHONE}}"), "sanitizer should redact phone numbers")
    expect(
        result.text.contains("{{ORDER_ID}}") || result.text.contains("{{CODE}}"),
        "sanitizer should redact numeric codes"
    )
    expect(result.text.contains("{{AMOUNT}}"), "sanitizer should redact amounts")
    expect(result.text.contains("{{URL}}"), "sanitizer should redact URLs")
}

func verificationClassifiesAsTransaction() {
    let decision = HeuristicClassifier().classify(sender: nil, body: "您的验证码 123456，请勿泄露。")

    expect(decision.labelID == "verification", "verification message should use verification label")
    expect(decision.systemAction == .transaction, "verification maps to transaction")
    expect(decision.confidence > 0.9, "verification heuristic should be high confidence")
}

func promotionClassifiesAsJunkWhenItContainsUnsubscribe() {
    let decision = HeuristicClassifier().classify(sender: nil, body: "限时优惠，回复T退订。")

    expect(decision.labelID == "promotion", "merchant offers with unsubscribe text should remain promotions")
    expect(decision.systemAction == .promotion, "promotions map to the promotion action")
}

func hasherProducesStableBuckets() {
    let hasher = FeatureHasher(dimension: 128)
    let first = hasher.features(sender: "95588", body: "验证码 123456")
    let second = hasher.features(sender: "95588", body: "验证码 123456")

    expect(first == second, "feature hashing should be stable")
    expect(!first.isEmpty, "feature hashing should produce features")
}

func checksumVerificationPassesForMatchingData() throws {
    let data = Data("model".utf8)
    let verifier = ModelManifestVerifier()
    let manifest = ModelManifest(
        version: "test",
        trainedAt: "2026-05-06T00:00:00Z",
        taxonomyHash: "taxonomy",
        featureHasherVersion: "v1",
        sha256: verifier.checksum(for: data),
        modelURL: nil
    )

    try verifier.verifyChecksum(of: data, manifest: manifest)
}

func sampleStoreRoundTrips() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-smoke-\(UUID().uuidString)")
        .appendingPathExtension("ndjson")
    let store = LocalSampleStore(fileURL: fileURL)
    try await store.append(
        StoredSample(sender: "", body: "您的验证码是 123456", labelID: "verification", source: "local")
    )
    let samples = try await store.loadAll()
    expect(samples.count == 1, "sample store should load appended samples")
    expect(samples[0].labelID == "verification", "sample store should preserve labels")
    try await store.removeAll()
}

customRuleBeatsClassifier()
higherPriorityRuleWins()
sanitizerRemovesObviousSensitiveTokens()
verificationClassifiesAsTransaction()
promotionClassifiesAsJunkWhenItContainsUnsubscribe()
hasherProducesStableBuckets()
try checksumVerificationPassesForMatchingData()
try await sampleStoreRoundTrips()

print("CoreSmokeTests passed")
