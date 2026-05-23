#if canImport(Testing)
import Foundation
import MessageFilterCore
import Testing

@Test
func customRuleBeatsClassifier() {
    let rule = CustomRule(
        name: "VIP sender",
        priority: 100,
        sender: SenderMatcher(kind: .exact, pattern: "95588"),
        targetLabelID: "finance.bank"
    )
    let pipeline = ClassificationPipeline()

    let decision = pipeline.classify(
        sender: "95588",
        body: "验证码 123456，请勿泄露。",
        rules: [rule]
    )

    #expect(decision.source == .rule)
    #expect(decision.labelID == "finance.bank")
    #expect(decision.systemAction == .transaction)
}

@Test
func senderSubstringRuleMatchesNormalizedSender() {
    let rule = CustomRule(
        name: "Bank sender substring",
        priority: 100,
        sender: SenderMatcher(kind: .substring, pattern: "955"),
        targetLabelID: "finance.bank"
    )

    let match = RuleEngine().match(
        sender: "+86 955-88",
        body: "验证码 123456，请勿泄露。",
        rules: [rule]
    )

    #expect(match?.label.id == "finance.bank")
}

@Test
func higherPriorityRuleWins() {
    let lower = CustomRule(
        name: "promotion",
        priority: 10,
        text: TextMatcher(kind: .keyword, pattern: "取件码"),
        targetLabelID: "promotion"
    )
    let higher = CustomRule(
        name: "pickup",
        priority: 20,
        text: TextMatcher(kind: .keyword, pattern: "取件码"),
        targetLabelID: "life.pickup_code"
    )

    let match = RuleEngine().match(sender: nil, body: "您的取件码 123456", rules: [lower, higher])

    #expect(match?.label.id == "life.pickup_code")
}

@Test
func sanitizerRemovesObviousSensitiveTokens() {
    let sanitizer = PrivacySanitizer()
    let result = sanitizer.sanitize("请联系 13800138000，验证码 843920，金额 ¥128.50，访问 https://example.com")

    #expect(result.text.contains("{{PHONE}}"))
    #expect(result.text.contains("{{ORDER_ID}}") || result.text.contains("{{CODE}}"))
    #expect(result.text.contains("{{AMOUNT}}"))
    #expect(result.text.contains("{{URL}}"))
}

@Test
func verificationClassifiesAsTransaction() {
    let decision = HeuristicClassifier().classify(sender: nil, body: "您的验证码 123456，请勿泄露。")

    #expect(decision.labelID == "verification")
    #expect(decision.systemAction == .transaction)
    #expect(decision.confidence > 0.9)
}

@Test
func promotionClassifiesAsJunkWhenItContainsUnsubscribe() {
    let decision = HeuristicClassifier().classify(sender: nil, body: "限时优惠，回复T退订。")

    #expect(decision.labelID == "spam")
    #expect(decision.systemAction == .junk)
}

@Test
func hasherProducesStableBuckets() {
    let hasher = FeatureHasher(dimension: 128)
    let first = hasher.features(sender: "95588", body: "验证码 123456")
    let second = hasher.features(sender: "95588", body: "验证码 123456")

    #expect(first == second)
    #expect(!first.isEmpty)
}

@Test
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
#endif
