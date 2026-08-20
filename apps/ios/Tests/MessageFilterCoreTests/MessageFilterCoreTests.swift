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

@Test
func governmentDailySafetyMessageClassifiesAsCivicReminder() {
    let decision = HeuristicClassifier().classify(
        sender: nil,
        body: "公安部治安管理局提示您：做好未成年人暑期安全监护，切勿到公开水域野泳，远离溺水风险。"
    )

    #expect(decision.labelID == "government.reminder")
    #expect(decision.systemAction == .transaction)
    #expect(decision.confidence > 0.9)
}

@Test(arguments: [
    "County police remind residents to keep children within sight near public swimming areas.",
    "City fire and rescue services advise replacing damaged extension leads before use.",
    "The consumer protection office advises checking a contractor's licence before paying a deposit.",
    "保健所からのお知らせです。調理済みの食品は早めに冷蔵してください。",
    "消費生活センターから、訪問販売の契約条件を確認するよう案内しています。"
])
func governmentReminderAuthorityVariantsClassifyAsCivicReminder(body: String) {
    let decision = HeuristicClassifier().classify(sender: nil, body: body)

    #expect(decision.labelID == "government.reminder")
    #expect(decision.systemAction == .transaction)
    #expect(decision.confidence > 0.9)
}

@Test
func expiringCloudResourceClassifiesAsWorkAlertInsteadOfVerification() {
    let decision = HeuristicClassifier().classify(
        sender: "CloudHost",
        body: "账号ID 568001 的云数据库实例 db-river7 即将到期；未续费将停止服务并删除备份，数据不可恢复。"
    )

    #expect(decision.labelID == "work.alert")
    #expect(decision.systemAction == .transaction)
    #expect(decision.confidence > 0.9)
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
    PromotionClassificationCase(text: "商务卡十月账单已生成，最低应缴金额将在27日到期。", expectedLabelID: "finance.credit_card"),
    PromotionClassificationCase(text: "Payment received: $500 applied to your card.", expectedLabelID: "finance.credit_card"),
    PromotionClassificationCase(text: "お支払いを確認しました：5,000円入金。ありがとうございます。", expectedLabelID: "finance.credit_card"),
    PromotionClassificationCase(text: "车载终端副卡本月通信费将随企业主号自动扣款。", expectedLabelID: "carrier.billing"),
    PromotionClassificationCase(text: "The fleet tracker companion SIM telecom charge will be debited with the corporate line.", expectedLabelID: "carrier.billing"),
    PromotionClassificationCase(text: "監視端末の追加SIM通信料は法人回線とまとめて引き落とします。", expectedLabelID: "carrier.billing"),
    PromotionClassificationCase(text: "中国移动月度账单已生成，本月应缴话费 88 元。", expectedLabelID: "carrier.billing"),
    PromotionClassificationCase(text: "中国联通套餐剩余 8GB 流量。", expectedLabelID: "carrier.data_reminder"),
    PromotionClassificationCase(text: "水费缴费成功，本次支付 88 元。", expectedLabelID: "transaction.other")
])
private func financialAndCarrierBoundariesClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
}

@Test(arguments: [
    PromotionClassificationCase(text: "企业卡月结单已出，本期最低还款额将在周四到期。", expectedLabelID: "finance.credit_card"),
    PromotionClassificationCase(text: "The corporate card statement lists a minimum amount due next Thursday.", expectedLabelID: "finance.credit_card"),
    PromotionClassificationCase(text: "業務カードの月次請求が確定し、最低支払額は木曜が期限です。", expectedLabelID: "finance.credit_card"),
    PromotionClassificationCase(text: "实验样本已存入冷冻柜C2，请凭提取码6041领取。", expectedLabelID: "life.pickup_code"),
    PromotionClassificationCase(text: "The lab sample is in cryogenic cabinet C2; collect it today using code 6041.", expectedLabelID: "life.pickup_code"),
    PromotionClassificationCase(text: "検体を冷凍庫C2へ保管しました。受取番号6041でお受け取りください。", expectedLabelID: "life.pickup_code"),
    PromotionClassificationCase(text: "遗属津贴资格复核已通过，调整金额将写入待遇记录。", expectedLabelID: "government.social_security"),
    PromotionClassificationCase(text: "The survivor-benefit eligibility review passed and the adjustment will appear in your benefit record.", expectedLabelID: "government.social_security"),
    PromotionClassificationCase(text: "遺族給付の資格確認が完了し、調整額を給付記録へ反映します。", expectedLabelID: "government.social_security"),
    PromotionClassificationCase(text: "压缩工作周申请已登记，新的考勤基准下月生效。", expectedLabelID: "work.attendance"),
    PromotionClassificationCase(text: "Your compressed-workweek request was recorded and the attendance policy changes next month.", expectedLabelID: "work.attendance"),
    PromotionClassificationCase(text: "週4日勤務の申請を登録し、来月から勤怠基準を変更します。", expectedLabelID: "work.attendance"),
    PromotionClassificationCase(text: "家庭地热年度保养优惠，签约赠送一次循环泵检测。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "The home-geothermal maintenance offer includes a free circulation-pump inspection.", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "家庭用地熱の保守キャンペーンで循環ポンプ点検が無料です。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "未处理交通违章需点开非官方链接并支付解锁费，否则将扣留驾驶证。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "An unpaid traffic ticket directs you to an unofficial link and demands an unlock fee to avoid license suspension.", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "交通違反通知の非公式リンクで解除料を払い、免許停止を回避するよう要求しています。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "采购申请PR-730进入财务复核，请确认成本中心后审批。", expectedLabelID: "work.approval"),
    PromotionClassificationCase(text: "Purchase request PR-730 reached finance review; approve it after checking the cost center.", expectedLabelID: "work.approval"),
    PromotionClassificationCase(text: "購買申請PR-730は財務確認中です。原価部門を確認して承認してください。", expectedLabelID: "work.approval"),
    PromotionClassificationCase(text: "应急部门提示：警报响起后请步行前往高地避难点。", expectedLabelID: "government.reminder"),
    PromotionClassificationCase(text: "Emergency officials advise walking to the high-ground refuge after the warning tone.", expectedLabelID: "government.reminder"),
    PromotionClassificationCase(text: "防災機関は警報後、徒歩で高台の避難所へ向かうよう案内しています。", expectedLabelID: "government.reminder"),
    PromotionClassificationCase(text: "本周排班调整为周五夜班，请确认考勤安排。", expectedLabelID: "work.attendance"),
    PromotionClassificationCase(text: "The roster changed and you now cover Friday night; confirm the attendance schedule.", expectedLabelID: "work.attendance"),
    PromotionClassificationCase(text: "勤務表が変更され金曜夜勤の担当になりました。勤怠予定を確認してください。", expectedLabelID: "work.attendance"),
    PromotionClassificationCase(text: "夜班门禁刷卡记录缺失，更正申请已补签。", expectedLabelID: "work.attendance"),
    PromotionClassificationCase(text: "The night-shift entry swipe is missing and a correction was filed.", expectedLabelID: "work.attendance"),
    PromotionClassificationCase(text: "夜勤の入館打刻が欠落し、修正申請を登録しました。", expectedLabelID: "work.attendance")
])
private func underrepresentedOperationalBoundariesClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
}

@Test(arguments: [
    PromotionClassificationCase(text: "本次住宿累计840奖励积分，当前可用余额为7620分。", expectedLabelID: "transaction.points"),
    PromotionClassificationCase(text: "This stay added 840 reward points; the available balance is now 7,620.", expectedLabelID: "transaction.points"),
    PromotionClassificationCase(text: "今回の宿泊で840ポイントが加算され、残高は7,620ポイントです。", expectedLabelID: "transaction.points"),
    PromotionClassificationCase(text: "免征信借款需要先缴账户激活费才能放款。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "A no-credit-check loan requires an account activation charge before release.", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "審査不要の融資は入金前に口座有効化手数料が必要です。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "冒充轮渡客服的消息要求先支付登记费并提供短信验证码。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "A message impersonating ferry support asks for a registration fee and SMS code.", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "フェリー窓口を装い、申請料の先払いと認証番号を要求しています。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "Your appliance order has been paid and the warehouse will dispatch it tomorrow.", expectedLabelID: "transaction.order"),
    PromotionClassificationCase(text: "Your home communications bill is ready and payment is due next Friday.", expectedLabelID: "carrier.billing"),
    PromotionClassificationCase(text: "The desktop client upgrade finished and added offline sync.", expectedLabelID: "transaction.message"),
    PromotionClassificationCase(text: "クリアホームのスマートロック先行予約。取付サービスと割引が付きます。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "市卫生部门提醒：高温时段减少户外活动并及时补水。", expectedLabelID: "government.reminder"),
    PromotionClassificationCase(text: "客服称退款失败，让您把验证码发过去以便人工入账。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "Support says the refund is stuck and asks you to forward the verification code.", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "返金失敗のため認証コードを転送すれば手動処理すると案内しています。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "Your cabinet order CX84219 is paid and the factory will ship it after inspection.", expectedLabelID: "transaction.order"),
    PromotionClassificationCase(text: "您的定制书桌订单FD81529已完成付款，工厂将在质检后安排发运。", expectedLabelID: "transaction.order"),
    PromotionClassificationCase(text: "Production log index audit-main is near its retention quota and may stop accepting writes.", expectedLabelID: "work.alert"),
    PromotionClassificationCase(text: "本番データベース orders-main の証明書は土曜に失効し、アプリから接続できなくなります。", expectedLabelID: "work.alert"),
    PromotionClassificationCase(text: "中央病院 confirms your follow-up appointment for Friday.", expectedLabelID: "life.medical"),
    PromotionClassificationCase(
        text: "自治体は台風訓練の警報後、表示に沿って屋内避難所へ移動するよう案内しています。",
        expectedLabelID: "government.reminder"
    ),
    PromotionClassificationCase(
        text: "The data-retention exception cleared security review and awaits Compliance approval.",
        expectedLabelID: "work.approval"
    )
])
private func acceptanceBoundaryVariantsClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
}

@Test(arguments: [
    PromotionClassificationCase(
        text: "【远洋客运】登船审核失败，请安装远程协助应用并共享屏幕完成证件检查。",
        expectedLabelID: "spam"
    ),
    PromotionClassificationCase(
        text: "A port-health notice directs passengers to install screen-sharing software for remote inspection.",
        expectedLabelID: "spam"
    ),
    PromotionClassificationCase(
        text: "Ferry refunds require your card PIN and online banking password before the fare can be released.",
        expectedLabelID: "spam"
    ),
    PromotionClassificationCase(
        text: "航空券の変更には商品券を購入し、引換番号を返信する必要があります。",
        expectedLabelID: "spam"
    ),
    PromotionClassificationCase(
        text: "轮渡订单已改签到周六，票价不变且无需再次付款，新船票见官方应用。",
        expectedLabelID: "travel.ticketing"
    ),
    PromotionClassificationCase(
        text: "Your cruise cabin upgrade is confirmed and its receipt is available in the official booking.",
        expectedLabelID: "travel.ticketing"
    ),
    PromotionClassificationCase(
        text: "鉄道予約は六号車から八号車へ変更されました。運賃は同じで追加決済はありません。",
        expectedLabelID: "travel.ticketing"
    ),
    PromotionClassificationCase(
        text: "【海湾轮渡】电子票已签发，可在官方应用查看；客服不会索取银行卡密码或短信动态码。",
        expectedLabelID: "travel.ticketing"
    ),
    PromotionClassificationCase(
        text: "海岸银行安全提醒：工作人员不会索取网银密码、短信验证码或要求远程控制手机。",
        expectedLabelID: "transaction.account_security"
    ),
    PromotionClassificationCase(
        text: "Harbor Bank security reminder: staff never request online-banking passwords or remote phone access.",
        expectedLabelID: "transaction.account_security"
    ),
    PromotionClassificationCase(
        text: "港湾銀行からの注意：職員がネット銀行のパスワードや遠隔操作を求めることはありません。",
        expectedLabelID: "transaction.account_security"
    )
])
private func travelTrustBoundariesClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
    #expect(decision.systemAction == SiftTaxonomy.leaf(id: example.expectedLabelID)?.systemAction)
}

@Test(arguments: [
    "Airline security reminder: staff will never ask you to share an online banking password or card PIN.",
    "航空会社からの注意：係員がネット銀行のパスワードやカード暗証番号を要求することはありません。"
])
private func travelCredentialSafetyRemindersAreNotForcedToSpam(body: String) {
    #expect(HeuristicClassifier.highPrecisionDecision(for: body)?.labelID != "spam")
}

@Test(arguments: [
    PromotionClassificationCase(
        text: "客户资料导出权限完成隐私审查，仍需产品所有者批准有效时长。",
        expectedLabelID: "work.approval"
    ),
    PromotionClassificationCase(
        text: "保証金残高を末尾9027の口座へ精算し、電子入金証明をダウンロードできます。",
        expectedLabelID: "finance.bank"
    ),
    PromotionClassificationCase(
        text: "The international-train wireless plan has 760 MB left through the final station.",
        expectedLabelID: "carrier.data_reminder"
    ),
    PromotionClassificationCase(
        text: "国際列車の無線プランは760MB残っており、終着駅まで有効です。",
        expectedLabelID: "carrier.data_reminder"
    ),
    PromotionClassificationCase(
        text: "Dining-table order TB4162 passed inspection; its voucher is for the next order.",
        expectedLabelID: "transaction.order"
    ),
    PromotionClassificationCase(
        text: "コーヒーマシン注文CM7305は梱包して発送済みで、会員券は次回購入用です。",
        expectedLabelID: "transaction.order"
    ),
    PromotionClassificationCase(
        text: "Coffee-machine order CM7305 was packed and dispatched; its voucher does not change this order's status.",
        expectedLabelID: "transaction.order"
    ),
    PromotionClassificationCase(
        text: "EA204便は発券済みです。搭乗QRと案内は航空会社のページで確認できます。",
        expectedLabelID: "travel.ticketing"
    )
])
private func operationalConfidenceBoundariesClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
    #expect(decision.systemAction == SiftTaxonomy.leaf(id: example.expectedLabelID)?.systemAction)
}

@Test(arguments: [
    PromotionClassificationCase(text: "交通部门公告：沿江隧道今晚封闭检修，请车辆绕行北桥。", expectedLabelID: "government.traffic"),
    PromotionClassificationCase(text: "The city will close Harbor Road overnight for maintenance; follow the marked detour.", expectedLabelID: "government.traffic"),
    PromotionClassificationCase(text: "道路局は橋の補修工事に伴い、今夜の通行を規制します。", expectedLabelID: "government.traffic"),
    PromotionClassificationCase(text: "运营商将在凌晨切换核心网，语音服务可能短暂中断。", expectedLabelID: "carrier.service"),
    PromotionClassificationCase(text: "The carrier is upgrading its voice service overnight and calls may be briefly unavailable.", expectedLabelID: "carrier.service"),
    PromotionClassificationCase(text: "通信会社は深夜に携帯ネットワークを保守し、作業後に自動復旧します。", expectedLabelID: "carrier.service"),
    PromotionClassificationCase(text: "季度奖金4,880元已发放并汇入工资卡。", expectedLabelID: "finance.income"),
    PromotionClassificationCase(text: "Payroll deposited the quarterly bonus into your registered account.", expectedLabelID: "finance.income"),
    PromotionClassificationCase(text: "四半期賞与が給与口座へ入金されました。", expectedLabelID: "finance.income"),
    PromotionClassificationCase(text: "住院理赔审核通过，保险金将在周五到账。", expectedLabelID: "finance.insurance"),
    PromotionClassificationCase(text: "The insurer approved your hospital claim and will transfer the benefit on Friday.", expectedLabelID: "finance.insurance"),
    PromotionClassificationCase(text: "入院保険の給付が承認され、金曜に入金されます。", expectedLabelID: "finance.insurance"),
    PromotionClassificationCase(text: "供水管线检修期间将暂停服务，预计下午恢复。", expectedLabelID: "life.utility"),
    PromotionClassificationCase(text: "The water utility will suspend service during scheduled pipe maintenance.", expectedLabelID: "life.utility"),
    PromotionClassificationCase(text: "水道局は配管工事のため供給を停止し、夕方に復旧します。", expectedLabelID: "life.utility"),
    PromotionClassificationCase(text: "项目会议改到周三，日历中的视频链接已经更新。", expectedLabelID: "work.meeting"),
    PromotionClassificationCase(text: "The project review moved to Wednesday and the meeting link was updated.", expectedLabelID: "work.meeting"),
    PromotionClassificationCase(text: "プロジェクト会議は水曜に変更され、リンクが更新されました。", expectedLabelID: "work.meeting"),
    PromotionClassificationCase(text: "海滨酒店确认了两晚住宿预订，请在入住时出示证件。", expectedLabelID: "travel.tourism"),
    PromotionClassificationCase(text: "The resort confirmed your two-night booking; show the reservation at check-in.", expectedLabelID: "travel.tourism"),
    PromotionClassificationCase(text: "ホテルの宿泊予約が確定しました。チェックイン時に予約書類をご提示ください。", expectedLabelID: "travel.tourism"),
    PromotionClassificationCase(text: "冒充快递客服的消息要求支付重新派送费并填写银行卡安全码。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "A fake delivery agent requests a redelivery fee and your card security code.", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "偽の配送業者が再配達料の支払いとカードのセキュリティコード入力を求めています。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "包裹投递失败，陌生页面要求支付重新投递费。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "A notice impersonating marine claims demands an advance file-review transfer.", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "本月工资已存入尾号6317账户。", expectedLabelID: "finance.income")
])
private func targetedGeneralizationBoundariesClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
    #expect(decision.systemAction == SiftTaxonomy.leaf(id: example.expectedLabelID)?.systemAction)
}

@Test(arguments: [
    "【港城旅行】提前预订海岛酒店套餐可享七折并赠早餐。",
    "Harbor Travel advance booking includes breakfast and a 30 percent discount.",
    "港町トラベルの早期予約。島のホテル2泊と朝食を通常料金から30%割引します。"
])
private func lodgingOffersAreLeftToTheLearnedClassifier(body: String) {
    #expect(HeuristicClassifier.highPrecisionDecision(for: body) == nil)
}

@Test(arguments: [
    PromotionClassificationCase(text: "您已从账户中移除设备，设备不能再访问个人资料。", expectedLabelID: "transaction.account_security"),
    PromotionClassificationCase(text: "You removed a device from the account, so it can no longer access your profile.", expectedLabelID: "transaction.account_security"),
    PromotionClassificationCase(text: "アカウントから端末を削除したため、プロフィールへアクセスできません。", expectedLabelID: "transaction.account_security"),
    PromotionClassificationCase(text: "云盘扩容页面要求输入钱包助记词才能保留文件。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "A cloud-storage page asks for your wallet recovery phrase to preserve files.", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "クラウド容量のページが保存のためにウォレット復元語を入力するよう要求しています。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "检验中心通知：血液检查报告已生成，可在医院应用查看。", expectedLabelID: "life.medical"),
    PromotionClassificationCase(text: "The laboratory report for your blood test is ready in the hospital app.", expectedLabelID: "life.medical"),
    PromotionClassificationCase(text: "血液検査の報告書が完成し、病院アプリで確認できます。", expectedLabelID: "life.medical"),
    PromotionClassificationCase(text: "年度隐私合规课程需在本月完成，学习记录将同步到员工档案。", expectedLabelID: "work.training"),
    PromotionClassificationCase(text: "Complete the annual privacy-compliance course; completion is recorded in your employee file.", expectedLabelID: "work.training"),
    PromotionClassificationCase(text: "年次プライバシー研修を修了し、受講記録を社員台帳に反映してください。", expectedLabelID: "work.training"),
    PromotionClassificationCase(text: "机场接驳巴士因道路施工改在6号站台上客。", expectedLabelID: "travel.transport"),
    PromotionClassificationCase(text: "Road works moved the airport shuttle pickup to stand 6.", expectedLabelID: "travel.transport"),
    PromotionClassificationCase(text: "道路工事のため空港連絡バスの乗り場は6番へ変更されます。", expectedLabelID: "travel.transport"),
    PromotionClassificationCase(text: "家庭会员升级申请已通过，新等级将在下个账期生效。", expectedLabelID: "transaction.member"),
    PromotionClassificationCase(text: "Your household membership upgrade was approved; the new tier begins next billing cycle.", expectedLabelID: "transaction.member"),
    PromotionClassificationCase(text: "ファミリー会員のランク変更が承認され、次回の請求期間から有効です。", expectedLabelID: "transaction.member")
])
private func v6SafetyAndOperationalBoundariesClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
    #expect(decision.systemAction == SiftTaxonomy.leaf(id: example.expectedLabelID)?.systemAction)
}

@Test(arguments: [
    PromotionClassificationCase(text: "Security center revoked the old browser token; a fresh session will require verification.", expectedLabelID: "transaction.account_security"),
    PromotionClassificationCase(text: "The platinum member benefits update is confirmed and takes effect on the next statement cycle.", expectedLabelID: "transaction.member"),
    PromotionClassificationCase(text: "Spring home-video promotion waives part of the first subscription month and adds subtitle downloads.", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "The unemployment-benefit review is complete; check the social-insurance account for the next payment date.", expectedLabelID: "government.social_security"),
    PromotionClassificationCase(text: "餐馆确认订单并开始烹饪，骑手接单后会发送送达预估。", expectedLabelID: "life.takeaway"),
    PromotionClassificationCase(text: "园区行政通知：周五东侧停车入口只对访客开放，员工请绕行。", expectedLabelID: "work.announcement"),
    PromotionClassificationCase(text: "Your high-speed rail e-ticket was issued; the gate QR code appears before departure.", expectedLabelID: "travel.ticketing"),
    PromotionClassificationCase(text: "口座末尾7314から本日89円を青嵐書店へ支払いました。", expectedLabelID: "finance.bank"),
    PromotionClassificationCase(text: "After tax withholding, the cash dividend from East Ridge Energy is available in your brokerage funds.", expectedLabelID: "finance.stock"),
    PromotionClassificationCase(text: "The weather office issued a cold-wave warning; mountain temperatures may fall below zero.", expectedLabelID: "life.weather"),
    PromotionClassificationCase(text: "货件已通过海关，正在前往沿海保税仓等待区域分拨。", expectedLabelID: "life.logistics"),
    PromotionClassificationCase(text: "The hospital lab uploaded your thyroid test report; view it in the patient app.", expectedLabelID: "life.medical"),
    PromotionClassificationCase(text: "The account security center ended access for an old tablet and will sign out its sessions.", expectedLabelID: "transaction.account_security"),
    PromotionClassificationCase(text: "The unemployment-benefit recheck passed and the payment record will update in your social-insurance account.", expectedLabelID: "government.social_security"),
    PromotionClassificationCase(text: "Office campus notice: the south staff entrance closes Monday; employees should use the west gate.", expectedLabelID: "work.announcement"),
    PromotionClassificationCase(text: "The airport shuttle temporarily boards at point 7; the flight connection schedule is unchanged.", expectedLabelID: "travel.transport"),
    PromotionClassificationCase(text: "Carrier points can be exchanged for a three-day data pass; redemption is open.", expectedLabelID: "carrier.promotion"),
    PromotionClassificationCase(text: "オフィス施設通知：月曜は南側の社員入口を閉鎖し、西門を利用してください。", expectedLabelID: "work.announcement"),
    PromotionClassificationCase(text: "空港連絡線は一時的に7番乗り場を使いますが、乗継時刻は変わりません。", expectedLabelID: "travel.transport")
])
private func v7GeneralizationBoundariesClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
    #expect(decision.systemAction == SiftTaxonomy.leaf(id: example.expectedLabelID)?.systemAction)
}

@Test(arguments: [
    PromotionClassificationCase(text: "クラウドアルバムの確認ページが、復元のためウォレットのシードフレーズを求めています。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "港口官方提示：登船牌只在人工柜台核验订单证件后发放，不会索取银行卡密码。", expectedLabelID: "travel.ticketing"),
    PromotionClassificationCase(text: "交通管理から、川沿い通りは日曜の工事中に通行止めとなるため迂回してください。", expectedLabelID: "government.traffic"),
    PromotionClassificationCase(text: "今月の家族医療保険キャンペーンは、オンライン保険料試算でクーポンが付きます。", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "Metro Pharmacy Black Friday: up to 35% off storewide deals.", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "中国电信积分商城开放，6000积分可换10GB流量包。", expectedLabelID: "carrier.promotion"),
    PromotionClassificationCase(text: "Checking account ending 3925 paid 186 dollars to Sunrise Clinic today; available funds were updated.", expectedLabelID: "finance.bank"),
    PromotionClassificationCase(text: "Your account will be disabled unless you use this unofficial page to submit a password and identity photo.", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "【邮轮母港】船票退款待领取，请点击https://ship-refund.example/verify填写银行卡信息。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "The insurer approved your claim and will transfer the benefit on Friday.", expectedLabelID: "finance.insurance"),
    PromotionClassificationCase(text: "The prescription refill is complete and the pharmacy will arrange pickup.", expectedLabelID: "life.medical")
])
private func v8SecondPassBoundariesClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
    #expect(decision.systemAction == SiftTaxonomy.leaf(id: example.expectedLabelID)?.systemAction)
}

@Test(arguments: [
    "【邮轮母港】船票退款待领取，请点击https://ship-refund.example/verify填写银行卡信息。",
    "Your ticket refund is ready to claim. Visit https://refund.example/claim and enter your card details.",
    "乗船券の返金をお受け取りください。https://refund.example/claim でカード情報を入力してください。"
])
private func refundClaimPagesRequestingBankCredentialsAreSpam(body: String) {
    let decision = HeuristicClassifier().classify(sender: nil, body: body)
    #expect(decision.labelID == "spam")
    #expect(decision.systemAction == .junk)
}

@Test(arguments: [
    "【飞猪】订单10045679901561退款已完成，金额860元已退回原支付账户，详情https://a.feizhu.com/Ab1Cd2",
    "Your refund is complete and is returning to the original card. Track it at https://travel.example/status.",
    "乗船券の返金が完了し、元のカードへ返金されました。状況：https://travel.example/status"
])
private func completedRefundStatusLinksRemainTransactions(body: String) {
    let decision = HeuristicClassifier().classify(sender: nil, body: body)
    #expect(decision.labelID == "finance.refund")
    #expect(decision.systemAction == .transaction)
}

@Test(arguments: [
    "商户撤销已确认，465元将在两个结算日内退回原支付账户。",
    "The merchant reversal is confirmed; $465 returns to the original payment account within two settlement days.",
    "加盟店の取消処理が確定し、465円を2決済日以内に元の支払口座へ戻します。"
])
private func completedMerchantReversalsStayRefundTransactions(body: String) {
    let decision = HeuristicClassifier().classify(sender: nil, body: body)
    #expect(decision.labelID == "finance.refund")
    #expect(decision.systemAction == .transaction)
}

@Test(arguments: [
    "供水公司发布煮沸提醒，西区管网冲洗完成前请勿直接饮用。",
    "The water utility issued a boil notice for the west district until network flushing is complete.",
    "水道局は西地区の管洗浄が終わるまで煮沸して飲むよう案内しています。"
])
private func utilityNoticesStayTransactional(body: String) {
    let decision = HeuristicClassifier().classify(sender: nil, body: body)
    #expect(decision.labelID == "life.utility")
    #expect(decision.systemAction == .transaction)
}

@Test(arguments: [
    PromotionClassificationCase(
        text: "クレジットカードの今月の請求額は2,430円、最低支払額は300円で、18日が支払期限です。",
        expectedLabelID: "finance.credit_card"
    ),
    PromotionClassificationCase(
        text: "尾号9048卡在机场书店消费73元，交易已确认。",
        expectedLabelID: "finance.consumption"
    ),
    PromotionClassificationCase(
        text: "Savings account ending 4082 was debited $28 at Harbor Pharmacy; the balance was updated.",
        expectedLabelID: "finance.bank"
    ),
    PromotionClassificationCase(
        text: "家庭宽带本月账单为196元，自动缴费将在19日执行。",
        expectedLabelID: "carrier.billing"
    ),
    PromotionClassificationCase(
        text: "Customers moving to the shared family plan receive two extra lines and weekend data.",
        expectedLabelID: "carrier.promotion"
    ),
    PromotionClassificationCase(
        text: "环境部门提醒：空气污染预警期间请减少长时间户外活动。",
        expectedLabelID: "government.reminder"
    ),
    PromotionClassificationCase(
        text: "デスクトップアプリの更新が完了し、オフライン検索機能を追加しました。",
        expectedLabelID: "transaction.message"
    ),
    PromotionClassificationCase(
        text: "The courier left the East Harbor depot and will deliver the parcel before noon.",
        expectedLabelID: "life.express"
    ),
    PromotionClassificationCase(
        text: "The balanced investment product is open for reservations in the official banking app.",
        expectedLabelID: "finance.wealth"
    ),
    PromotionClassificationCase(
        text: "安稳组合赎回已完成，结算款将在两个工作日内到账。",
        expectedLabelID: "finance.wealth"
    ),
    PromotionClassificationCase(
        text: "办公园区通知：周一南门关闭，员工请改走西门。",
        expectedLabelID: "work.announcement"
    ),
    PromotionClassificationCase(
        text: "包裹被扣留，请在陌生页面支付解锁费并填写银行卡信息后再派送。",
        expectedLabelID: "spam"
    ),
    PromotionClassificationCase(
        text: "夕食の注文を配達員が受け取り、19時25分に到着予定です。",
        expectedLabelID: "life.takeaway"
    ),
    PromotionClassificationCase(
        text: "冷冻餐盒已存入社区冷柜D03，提取密码为2907，请在21点前领取。",
        expectedLabelID: "life.pickup_code"
    ),
    PromotionClassificationCase(
        text: "The maternity-benefit eligibility review passed; the supplemental payment will appear in the social-benefits account.",
        expectedLabelID: "government.social_security"
    ),
    PromotionClassificationCase(
        text: "Your custom-desk dimensions and final payment are confirmed; the workshop starts production next week.",
        expectedLabelID: "transaction.order"
    ),
    PromotionClassificationCase(
        text: "Signal repairs shortened the airport express route; transfer to a replacement bus at Central Station for the terminal.",
        expectedLabelID: "travel.transport"
    )
])
private func classicCrossDomainBoundaryVariantsClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
    #expect(decision.systemAction == SiftTaxonomy.leaf(id: example.expectedLabelID)?.systemAction)
}

@Test(arguments: [
    PromotionClassificationCase(
        text: "カード請求額は517,000円、最低支払額は51,700円で、10月3日が期限です。",
        expectedLabelID: "finance.credit_card"
    ),
    PromotionClassificationCase(
        text: "自称法院执行人员要求购买购物卡抵扣罚金，并把卡号通过短信发送。",
        expectedLabelID: "spam"
    )
])
private func v9ClassicSafetyRegressionsClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
    #expect(decision.systemAction == SiftTaxonomy.leaf(id: example.expectedLabelID)?.systemAction)
}

@Test
private func officialCourtNoticeDoesNotTriggerImpersonationSpamRule() {
    let decision = HeuristicClassifier.highPrecisionDecision(
        for: "市中级法院通知：案件材料补充期限为9月6日，请通过诉讼服务平台查看清单。"
    )
    #expect(decision?.labelID != "spam")
}

@Test(arguments: [
    PromotionClassificationCase(
        text: "应急部门提醒：社区疏散演练鸣笛时请沿绿色标识前往东广场。",
        expectedLabelID: "government.reminder"
    ),
    PromotionClassificationCase(
        text: "Emergency services ask residents to follow green signs to the east square when the evacuation-drill siren sounds.",
        expectedLabelID: "government.reminder"
    ),
    PromotionClassificationCase(
        text: "防災当局は避難訓練のサイレン後、緑の表示に沿って東広場へ移動するよう案内しています。",
        expectedLabelID: "government.reminder"
    )
])
private func disasterEvacuationRemindersStayTransactional(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
    #expect(decision.systemAction == .transaction)
}

@Test(arguments: [
    PromotionClassificationCase(text: "尾号6682卡在海湾高速收费站完成42元通行支付，交易已入账。", expectedLabelID: "finance.consumption"),
    PromotionClassificationCase(text: "A $42 toll-road purchase posted to the card ending 6682 at Bay Expressway.", expectedLabelID: "finance.consumption"),
    PromotionClassificationCase(text: "末尾6682のカードで湾岸高速料金42円を支払い、利用明細へ反映しました。", expectedLabelID: "finance.consumption"),
    PromotionClassificationCase(text: "运营商语音信箱转写平台周五凌晨升级，维护窗口内新留言仍会保存但暂不生成文字。", expectedLabelID: "carrier.service"),
    PromotionClassificationCase(text: "The carrier upgrades voicemail transcription Friday morning; new messages remain saved but text will be delayed.", expectedLabelID: "carrier.service"),
    PromotionClassificationCase(text: "通信会社は金曜未明に留守番電話文字化基盤を更新し、録音は保存しますが文字表示が遅れます。", expectedLabelID: "carrier.service"),
    PromotionClassificationCase(text: "排水公司提醒：东岸管道清淤期间请勿向地漏大量排水，作业预计下午结束。", expectedLabelID: "life.utility"),
    PromotionClassificationCase(text: "The wastewater utility asks Eastbank residents to limit drain discharge while sewer cleaning continues this afternoon.", expectedLabelID: "life.utility"),
    PromotionClassificationCase(text: "下水道事業者は東岸地区の管清掃中、午後の作業終了まで大量排水を控えるよう案内しています。", expectedLabelID: "life.utility"),
    PromotionClassificationCase(text: "恒温试剂包已放入科研楼冷柜E6，请凭提取码5731在四小时内领取。", expectedLabelID: "life.pickup_code"),
    PromotionClassificationCase(text: "The temperature-controlled reagent parcel is in research-building freezer E6; collect it within four hours using PIN 5731.", expectedLabelID: "life.pickup_code"),
    PromotionClassificationCase(text: "定温試薬の荷物を研究棟冷凍庫E6へ保管しました。引取番号5731で4時間以内にお受け取りください。", expectedLabelID: "life.pickup_code"),
    PromotionClassificationCase(text: "家事法院已接收遗产清册补充材料，下一次线上询问日期将在排期后送达。", expectedLabelID: "government.court"),
    PromotionClassificationCase(text: "The family court received the supplemental estate inventory and will serve the next online-hearing date after scheduling.", expectedLabelID: "government.court"),
    PromotionClassificationCase(text: "家庭裁判所が遺産目録の追加資料を受領し、日程確定後に次回オンライン審理日を送達します。", expectedLabelID: "government.court"),
    PromotionClassificationCase(text: "火山防灾部门提示：演练警报响起后请佩戴口罩，沿蓝色路线前往室内避难所。", expectedLabelID: "government.reminder"),
    PromotionClassificationCase(text: "Volcano emergency officials advise wearing a mask and following the blue route to the indoor shelter after the drill alarm.", expectedLabelID: "government.reminder"),
    PromotionClassificationCase(text: "火山防災機関は訓練警報後、マスクを着け青い経路で屋内避難所へ移動するよう案内しています。", expectedLabelID: "government.reminder"),
    PromotionClassificationCase(text: "供应商风险评估VR-552已完成法务核对，等待业务负责人批准付款周期。", expectedLabelID: "work.approval"),
    PromotionClassificationCase(text: "Supplier risk review VR-552 cleared Legal and awaits the business owner's approval of payment terms.", expectedLabelID: "work.approval"),
    PromotionClassificationCase(text: "取引先リスク審査VR-552は法務確認済みで、事業責任者の支払条件承認待ちです。", expectedLabelID: "work.approval"),
    PromotionClassificationCase(text: "夜行卧铺列车电子票已签发，请在出发前于6号检票口出示乘车二维码。", expectedLabelID: "travel.ticketing"),
    PromotionClassificationCase(text: "Your overnight sleeper-train e-ticket was issued; show its travel QR code at gate 6 before departure.", expectedLabelID: "travel.ticketing"),
    PromotionClassificationCase(text: "夜行寝台列車の電子乗車券を発行しました。出発前に6番改札で乗車QRをご提示ください。", expectedLabelID: "travel.ticketing"),
    PromotionClassificationCase(text: "有轨电车因供电检修缩短线路，前往大学城请在中央公园换乘代行巴士。", expectedLabelID: "travel.transport"),
    PromotionClassificationCase(text: "Power repairs shortened the tram route; transfer to the replacement bus at Central Park for University District.", expectedLabelID: "travel.transport"),
    PromotionClassificationCase(text: "給電点検で路面電車は区間運転となり、大学地区へは中央公園で代行バスに乗り換えてください。", expectedLabelID: "travel.transport")
])
private func v12CompositionBoundariesClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
    #expect(decision.systemAction == .transaction)
}

@Test(arguments: [
    PromotionClassificationCase(
        text: "The carrier is upgrading its emergency-broadcast gateway; test alerts may arrive late during maintenance.",
        expectedLabelID: "carrier.service"
    ),
    PromotionClassificationCase(
        text: "海水供冷服务中心通知：换热管清洗期间东区制冷将暂停两小时。",
        expectedLabelID: "life.utility"
    ),
    PromotionClassificationCase(
        text: "天文台登山齿轨车电子往返票已签发，请在山脚闸机出示二维码。",
        expectedLabelID: "travel.ticketing"
    )
])
private func v15RuleCalibrationDoesNotOverrideCorrectDomains(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
    #expect(decision.systemAction == .transaction)
}

@Test(arguments: [
    PromotionClassificationCase(text: "Miles from several rail journeys were posted; your member-points balance is now 9,840.", expectedLabelID: "transaction.points"),
    PromotionClassificationCase(text: "市立資料館の年会員資格を更新し、有効期限は来年8月末になりました。", expectedLabelID: "transaction.member"),
    PromotionClassificationCase(text: "暗号化メール保管庫の書き出しが完了し、管理画面から6日間ダウンロードできます。", expectedLabelID: "transaction.message"),
    PromotionClassificationCase(text: "Pathology specimens transferred from the regional laboratory to the specialist hospital under normal cold-chain conditions.", expectedLabelID: "life.logistics"),
    PromotionClassificationCase(text: "歴史地区の宿で3泊予約を確定しました。到着時に受付で予約書類をご提示ください。", expectedLabelID: "travel.tourism"),
    PromotionClassificationCase(text: "The valley funicular is suspended after a landslide; replacement shuttles leave the station square.", expectedLabelID: "travel.transport"),
    PromotionClassificationCase(text: "夜航渡轮卧铺电子票已签发，请在五码头闸机出示二维码。", expectedLabelID: "travel.ticketing"),
    PromotionClassificationCase(text: "The backup vault encryption master key expires in 20 hours and will stop nightly backups unless rotated.", expectedLabelID: "work.alert"),
    PromotionClassificationCase(text: "Early booking for the city museum restoration workshop waives one materials fee for pairs.", expectedLabelID: "promotion"),
    PromotionClassificationCase(text: "Emergency officials advise following the orange markings to the indoor shelter when the typhoon drill alarm sounds.", expectedLabelID: "government.reminder"),
    PromotionClassificationCase(text: "A new security key was registered on your account; the previous recovery device remains authorized.", expectedLabelID: "transaction.account_security"),
    PromotionClassificationCase(text: "Your disability allowance annual review passed; the revised benefit will appear in social-security history.", expectedLabelID: "government.social_security"),
    PromotionClassificationCase(text: "采购合规申请已完成供应商核验，等待财务负责人批准付款周期。", expectedLabelID: "work.approval"),
    PromotionClassificationCase(text: "Your flexible-schedule request was approved; Monday's clock-in time and attendance rules were updated.", expectedLabelID: "work.attendance"),
    PromotionClassificationCase(text: "The refrigerated vaccine parcel is in hospital freezer H8; use pickup PIN 9150 within two hours.", expectedLabelID: "life.pickup_code"),
    PromotionClassificationCase(text: "The home-water service campaign includes one free filter inspection with a booked annual visit.", expectedLabelID: "promotion")
])
private func v16GeneralizationRulesClassifyComposedDomains(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
    #expect(decision.systemAction == SiftTaxonomy.leaf(id: example.expectedLabelID)?.systemAction)
}

@Test(arguments: [
    PromotionClassificationCase(text: "证券账户中的限价买单已成交。", expectedLabelID: "finance.stock"),
    PromotionClassificationCase(text: "Your limit stock order was filled in the brokerage account.", expectedLabelID: "finance.stock"),
    PromotionClassificationCase(text: "証券口座の株式指値注文が約定しました。", expectedLabelID: "finance.stock"),
    PromotionClassificationCase(text: "理财产品今日到期，本金正在结算。", expectedLabelID: "finance.wealth"),
    PromotionClassificationCase(text: "The managed investment product matured and its principal is settling.", expectedLabelID: "finance.wealth"),
    PromotionClassificationCase(text: "運用商品が満期となり、元本を決済中です。", expectedLabelID: "finance.wealth"),
    PromotionClassificationCase(text: "电子税务局已受理申报，回执可以下载。", expectedLabelID: "government.tax"),
    PromotionClassificationCase(text: "The tax office accepted the filing and posted its receipt.", expectedLabelID: "government.tax"),
    PromotionClassificationCase(text: "税務署が申告を受理し、受付票を発行しました。", expectedLabelID: "government.tax"),
    PromotionClassificationCase(text: "社保养老保险缴费记录已更新。", expectedLabelID: "government.social_security"),
    PromotionClassificationCase(text: "The social-security pension contribution record was updated.", expectedLabelID: "government.social_security"),
    PromotionClassificationCase(text: "社会保険の年金保険料記録が更新されました。", expectedLabelID: "government.social_security"),
    PromotionClassificationCase(text: "运单已进入干线运输并前往区域分拨仓。", expectedLabelID: "life.logistics"),
    PromotionClassificationCase(text: "The shipment entered line-haul transport for the distribution warehouse.", expectedLabelID: "life.logistics"),
    PromotionClassificationCase(text: "貨物は幹線輸送に入り、地域の仕分け倉庫へ向かっています。", expectedLabelID: "life.logistics"),
    PromotionClassificationCase(text: "您有来自010-8821的未接来电，对方没有语音留言。", expectedLabelID: "carrier.call_reminder"),
    PromotionClassificationCase(text: "You have a missed call from 010-8821 and the caller left no voicemail.", expectedLabelID: "carrier.call_reminder"),
    PromotionClassificationCase(text: "010-8821から不在着信があり、留守番電話はありません。", expectedLabelID: "carrier.call_reminder"),
    PromotionClassificationCase(text: "公司公告：办公楼周五举行消防演练。", expectedLabelID: "work.announcement"),
    PromotionClassificationCase(text: "Company announcement: the office holds a fire drill Friday.", expectedLabelID: "work.announcement"),
    PromotionClassificationCase(text: "社内告知：金曜にオフィスで消防訓練を行います。", expectedLabelID: "work.announcement"),
    PromotionClassificationCase(text: "数据安全培训包含课程和在线测验，请按期完成。", expectedLabelID: "work.training"),
    PromotionClassificationCase(text: "Data-security training includes a course and online assessment to complete.", expectedLabelID: "work.training"),
    PromotionClassificationCase(text: "データ安全研修は受講後にオンライン試験があります。", expectedLabelID: "work.training"),
    PromotionClassificationCase(text: "城际列车晚点，检票口临时调整。", expectedLabelID: "travel.transport"),
    PromotionClassificationCase(text: "The intercity train is delayed and its boarding gate changed.", expectedLabelID: "travel.transport"),
    PromotionClassificationCase(text: "都市間列車が遅れ、改札口も変更されました。", expectedLabelID: "travel.transport"),
    PromotionClassificationCase(text: "处方续配完成，药房将安排取药。", expectedLabelID: "life.medical"),
    PromotionClassificationCase(text: "The prescription refill is complete and the pharmacy will arrange pickup.", expectedLabelID: "life.medical"),
    PromotionClassificationCase(text: "継続処方が完了し、薬局が受取を手配します。", expectedLabelID: "life.medical"),
    PromotionClassificationCase(text: "外卖骑手已取餐，正在送往地址。", expectedLabelID: "life.takeaway"),
    PromotionClassificationCase(text: "The rider collected your meal and is heading to the delivery address.", expectedLabelID: "life.takeaway"),
    PromotionClassificationCase(text: "配達員が食事を受け取り、届け先へ向かっています。", expectedLabelID: "life.takeaway"),
    PromotionClassificationCase(text: "荐股群保证上涨，要求把入群费转入私人账户。", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "A private stock group guarantees gains after an entry fee reaches a personal account.", expectedLabelID: "spam"),
    PromotionClassificationCase(text: "株情報グループが上昇を保証し、参加費を個人口座へ送るよう求めています。", expectedLabelID: "spam")
])
private func v5RegressionBoundaryVariantsClassifyCorrectly(example: PromotionClassificationCase) {
    let decision = HeuristicClassifier().classify(sender: nil, body: example.text)
    #expect(decision.labelID == example.expectedLabelID)
    #expect(decision.systemAction == SiftTaxonomy.leaf(id: example.expectedLabelID)?.systemAction)
}

@Test(arguments: [
    "课程小组改成线上讨论，你看到群里发的会议链接了吗？",
    "Here is the library registration link. Would you like to go together this weekend?",
    "授業討論はオンラインです。会議リンクは届きましたか。",
    "电影票的钱已经转回给你了，晚点确认一下。",
    "家に着いたら連絡してください。忘れていった充電器は明日持っていきます。"
])
private func personalBoundaryMessagesAbstain(body: String) {
    let decision = HeuristicClassifier().classify(sender: nil, body: body)
    #expect(ModelOutputContract.isAbstainLabel(decision.labelID))
    #expect(decision.systemAction == .none)
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
