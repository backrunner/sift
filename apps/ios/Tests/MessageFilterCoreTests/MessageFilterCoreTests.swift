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
        action: .allow
    )
    let pipeline = ClassificationPipeline()

    let decision = pipeline.classify(
        sender: "95588",
        body: "验证码 123456，请勿泄露。",
        rules: [rule]
    )

    #expect(decision.source == .rule)
    #expect(decision.labelID == "transaction.message")
    #expect(decision.systemAction == .none)
}

@Test
func senderSubstringRuleMatchesNormalizedSender() {
    let rule = CustomRule(
        name: "Bank sender substring",
        priority: 100,
        sender: SenderMatcher(kind: .substring, pattern: "955"),
        action: .allow
    )

    let match = RuleEngine().match(
        sender: "+86 955-88",
        body: "验证码 123456，请勿泄露。",
        rules: [rule]
    )

    #expect(match?.rule.action == .allow)
}

@Test
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

    #expect(match?.rule.action == .allow)
}

@Test
func blockRuleRoutesMatchingMessageToJunk() {
    let rule = CustomRule(
        name: "Block sender",
        sender: SenderMatcher(kind: .exact, pattern: "10690000"),
        action: .block
    )

    let decision = ClassificationPipeline().classify(
        sender: "10690000",
        body: "Your order is ready",
        rules: [rule]
    )

    #expect(decision.source == .rule)
    #expect(decision.labelID == "spam")
    #expect(decision.systemAction == .junk)
}

@Test
func allowRuleCannotBeOverriddenByCategoryMapping() {
    let rule = CustomRule(
        name: "Allow sender",
        sender: SenderMatcher(kind: .prefix, pattern: "955"),
        action: .allow
    )

    let decision = ClassificationPipeline()
        .classify(sender: "95588", body: "Account notice", rules: [rule])
        .applying(categoryMappings: ["transaction.message": .junk])

    #expect(decision.source == .rule)
    #expect(decision.systemAction == .none)
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
func merchantPromotionWithUnsubscribeRemainsPromotion() {
    let decision = HeuristicClassifier().classify(sender: nil, body: "限时优惠，回复T退订。")

    #expect(decision.labelID == "promotion")
    #expect(decision.systemAction == .promotion)
}

private struct SubmissionSimilarityCase: Sendable {
    let first: String
    let second: String
    let expected: Bool
}

@Test(arguments: [
    SubmissionSimilarityCase(
        first: "游戏2.8版本更新完成，新增地图并修复组队掉线问题。",
        second: "游戏2.9版本更新完成，新增地图并修复组队掉线问题。",
        expected: true
    ),
    SubmissionSimilarityCase(
        first: "您的验证码为123456，请勿告知他人。",
        second: "您的验证码为 654321，请勿告知他人！",
        expected: true
    ),
    SubmissionSimilarityCase(
        first: "银行商城积分兑换活动今日开始。",
        second: "地铁二号线今天临时调整运行时间。",
        expected: false
    ),
    SubmissionSimilarityCase(first: "新品上线", second: "新品发布", expected: false)
])
private func submissionSimilarityIsConservative(example: SubmissionSimilarityCase) {
    #expect(SubmissionSimilarity.isSimilar(example.first, example.second) == example.expected)
}

@Test
func localSampleStoreRejectsSimilarSamplesOnlyWithinTheSameLabel() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SiftTests.\(UUID().uuidString)", isDirectory: true)
    let store = LocalSampleStore(fileURL: directory.appendingPathComponent("samples.ndjson"))
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = StoredSample(sender: "", body: "游戏充值100元赠送20%钻石。", labelID: "promotion", source: "local")
    let duplicate = StoredSample(sender: "", body: "游戏充值200元赠送30%钻石。", labelID: "promotion", source: "local")
    let correction = StoredSample(sender: "", body: duplicate.body, labelID: "spam", source: "local")

    #expect(try await store.appendIfUnique(first))
    #expect(try await store.appendIfUnique(duplicate) == false)
    #expect(try await store.appendIfUnique(correction))
    #expect(try await store.loadAll().count == 2)
}

private struct PromotionClassificationCase: Sendable {
    let text: String
    let expectedLabelID: String
}

@Test(arguments: [
    PromotionClassificationCase(text: "热门手游新服开启，首充双倍并赠送限定皮肤礼包。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "游戏道具和金币交易专区限时免手续费，认证商家再送券。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "银行卡积分商城上新，积分兑换家电再享抽奖机会。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "银行商城会员日，指定商品满500减80。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "服装店换季折扣，两件七折，回复T退订。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "周末超市特卖，粮油日用品第二件半价。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "New game server launch: first top-up bonus and limited in-game items.", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "Bank rewards mall sale: redeem points for gift cards this weekend.", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "ゲーム新サーバー開設、初回チャージで限定スキンをプレゼント。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "銀行ポイントモールで家電交換キャンペーン実施中。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "中国电信积分商城限时开放，可兑换流量包。", expectedLabelID: "carrier.promotion"),
    PromotionClassificationCase(text: "本次消费获得积分500分，积分余额已更新。", expectedLabelID: "transaction.points"),
    PromotionClassificationCase(text: "手游充值节开启，充值返利并赠送限定头像框。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "本行贷款利率优惠，请在官方App查看完整费用。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "游戏版本更新完成，新地图已经开放。", expectedLabelID: "transaction.message"),
    PromotionClassificationCase(text: "春季新品上线，会员预订享优惠。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "地铁旁新房源出租，预约看房享租金优惠。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "无视征信，当天放款，先交保证金。", expectedLabelID: "spam")
])
private func expandedPromotionSegmentsClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)

    #expect(decision.labelID == example.expectedLabelID)
}

@Test(arguments: [
    PromotionClassificationCase(text: "信用卡分期购买手机 3200 元，首期支付已完成。", expectedLabelID: "finance.consumption"),
    PromotionClassificationCase(text: "尾号4821信用卡在青禾超市消费268.50元，交易已入账。", expectedLabelID: "finance.consumption"),
    PromotionClassificationCase(text: "Installment purchase at Northwind Market: $320 was paid with your card.", expectedLabelID: "finance.consumption"),
    PromotionClassificationCase(text: "Card ending 4821 was used for a $268.50 grocery purchase at GreenLeaf Market.", expectedLabelID: "finance.consumption"),
    PromotionClassificationCase(text: "末尾4821のカードでスーパーにて26,850円を利用しました。", expectedLabelID: "finance.consumption"),
    PromotionClassificationCase(text: "信用卡还款成功，入账金额 654.27 元。", expectedLabelID: "finance.credit_card"),
    PromotionClassificationCase(text: "Your credit card statement is ready. Amount due $603.50.", expectedLabelID: "finance.credit_card"),
    PromotionClassificationCase(text: "Payment received: $500 applied to your card.", expectedLabelID: "finance.credit_card"),
    PromotionClassificationCase(text: "お支払いを確認しました：5,000円入金。ありがとうございます。", expectedLabelID: "finance.credit_card"),
    PromotionClassificationCase(text: "中国移动月度账单已生成，本月应缴话费 88 元。", expectedLabelID: "carrier.billing"),
    PromotionClassificationCase(text: "中国联通套餐剩余 8GB 流量。", expectedLabelID: "carrier.data_reminder"),
    PromotionClassificationCase(text: "水费缴费成功，本次支付 88 元。", expectedLabelID: "transaction.other")
])
private func financialAndCarrierBoundariesClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
}

@Test
func gameItemMarketplacePromotionAndOrderBoundaryIsPrecise() {
    let classifier = HeuristicClassifier()
    let promotion = classifier.classify(
        sender: nil,
        body: "【ECOSTEAM】武库轮换更新，一星起开，即开即售。请及时更新货架信息！"
    )
    let order = classifier.classify(
        sender: nil,
        body: "您的游戏道具订单 EC20260711 已支付，卖家正在准备交付。"
    )

    #expect(promotion.labelID == "promotion")
    #expect(order.labelID == "transaction.order")
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
