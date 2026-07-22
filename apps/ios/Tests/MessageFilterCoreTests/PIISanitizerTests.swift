#if canImport(Testing)
import Foundation
@testable import MessageFilterCore
import Testing

private struct PlatePositiveFixture: Decodable {
    let text: String
    let value: String
}

private struct CleanPIIFixture: Decodable {
    let text: String
}

private func piiEvaluationURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tools/pii-trainer/Evaluation/\(name)")
}

private func loadNDJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
    let contents = try String(contentsOf: url, encoding: .utf8)
    return try contents.split(whereSeparator: \.isNewline).map { line in
        try JSONDecoder().decode(T.self, from: Data(line.utf8))
    }
}

// MARK: - Rule-track sanitizer coverage

@Test
func sanitizerRedactsChineseIDNumbers() {
    let sanitizer = PrivacySanitizer()

    let modern = sanitizer.sanitize("请核对身份证号 11010519880605123X 后办理。")
    #expect(modern.text.contains("{{ID}}"))
    #expect(!modern.text.contains("11010519880605123X"))

    let legacy = sanitizer.sanitize("旧证件号130503670401001，请更新。")
    #expect(legacy.text.contains("{{ID}}"))
    #expect(!legacy.text.contains("130503670401001"))
}

@Test
func sanitizerRedactsPassportNumbers() {
    let sanitizer = PrivacySanitizer()
    let result = sanitizer.sanitize("Passport E12345678 has been approved.")
    #expect(result.text.contains("{{ID}}"))
    #expect(!result.text.contains("E12345678"))
}

@Test
func sanitizerRedactsVerificationCodesWithNaturalParticles() {
    let sanitizer = PrivacySanitizer()
    let samples = [
        "您的验证码是 482913，请勿告知他人。",
        "Your verification code is 482913. Do not share it.",
        "認証コードは482913です。第三者に共有しないでください。"
    ]

    for sample in samples {
        let result = sanitizer.sanitize(sample)
        #expect(result.text.contains("{{CODE}}"))
        #expect(!result.text.contains("482913"))
    }
}

@Test
func sanitizerRedactsJapanesePhoneWithContactContext() {
    let sanitizer = PrivacySanitizer()
    let result = sanitizer.sanitize("090-1234-5678に連絡してください。")

    #expect(result.text.contains("{{PHONE}}"))
    #expect(!result.text.contains("090-1234-5678"))
}

@Test
func sanitizerRedactsVehicleLicensePlates() {
    let sanitizer = PrivacySanitizer()
    let samples = [
        ("车辆京A12345已进入停车场。", "京A12345"),
        ("新能源车牌粤BD12345已绑定。", "粤BD12345"),
        ("执勤车辆京A1234警已到达。", "京A1234警"),
        ("领事车辆沪A1234领已登记。", "沪A1234领"),
        ("車両番号は品川 300 あ 12-34です。", "品川 300 あ 12-34"),
        ("ナンバープレートは横浜300わ12-34です。", "横浜300わ12-34"),
        ("French license plate AB-123-CD was checked in.", "AB-123-CD"),
        ("Kfz-Kennzeichen B-AB 1234 wurde erfasst.", "B-AB 1234"),
        ("La targa AB 123 CD è stata registrata.", "AB 123 CD"),
        ("La matrícula del vehículo 1234 BCD fue verificada.", "1234 BCD"),
        ("Kenteken AB-12-CD is bij de slagboom gelezen.", "AB-12-CD"),
        ("A matrícula do veículo 12-AB-34 foi verificada.", "12-AB-34"),
        ("Plaque d'immatriculation 1-ABC-123 enregistrée.", "1-ABC-123"),
        ("Kennzeichen des Fahrzeugs ZH 123456 wurde erfasst.", "ZH 123456"),
        ("Vehicle registration 241-D-12345 was recorded.", "241-D-12345"),
        ("Fordonets registreringsnummer ABC 12D har registrerats.", "ABC 12D"),
        ("Nummerplade AB 12 345 blev registreret.", "AB 12 345"),
        ("Ajoneuvon rekisteritunnus ABC-123 tallennettiin.", "ABC-123"),
        ("Numer rejestracyjny pojazdu WX 1234A został zapisany.", "WX 1234A"),
        ("Vehicle plate AB12 CDE entered the car park.", "AB12 CDE"),
        ("License plate 8ABC123 entered the garage.", "8ABC123"),
        ("license plate ab1234 entered the garage.", "ab1234"),
        ("香港車牌 AB 1234 已進入停車場。", "AB 1234"),
        ("香港車牌 9 已完成登記。", "9")
    ]

    for (text, plate) in samples {
        let result = sanitizer.sanitize(text)
        #expect(result.text.contains("{{PLATE}}"))
        #expect(!result.text.contains(plate))
        #expect(result.redactions.contains { redaction in
            redaction.token == "{{PLATE}}" && String(text[redaction.range]) == plate
        })
    }
}

@Test
func sanitizerKeepsPlateLikeIdentifiersWithoutPlateEvidence() {
    let sanitizer = PrivacySanitizer()
    let samples = [
        "航班 CA1234 预计十八点起飞。",
        "产品型号 AB1234 已上新。",
        "产品型号粤B12345已上新，共有三种颜色。",
        "产品型号粤B12345，车牌信息尚未填写。",
        "粤B12345 是产品型号，不是车辆号牌。",
        "Order AB-1234 is ready for pickup.",
        "予約番号品川 300 あ 12-34です。",
        "品川 300 あ 12-34は予約番号で、車両番号ではありません。",
        "License plate ABCDEFGHIJK was entered incorrectly.",
        "License plate is invalid and must be entered again.",
        "Plate number unknown was not accepted.",
        "车牌号 abcdefghijk 不是有效号牌。",
        "Campaign 1234 BCD starts tomorrow.",
        "Software build AB12 CDE passed all checks.",
        "Student matrícula AB1234 was renewed.",
        "La matrícula universitaria 1234 BCD corresponde al estudiante.",
        "A matrícula escolar 12-AB-34 pertence ao aluno.",
        "Immatriculation AB1234 belongs to a company record.",
        "Immatriculation du registre 1-ABC-123 concerne une société.",
        "Kennzeichen 1234 BCD is a catalog reference.",
        "Targa AB1234 is the product code.",
        "Kenteken 8ABC123 is an account identifier.",
        "French license plate 8ABC123 is not a valid French registration.",
        "American license plate AB-123-CD is not a supported US format."
    ]

    for sample in samples {
        #expect(!sanitizer.sanitize(sample).text.contains("{{PLATE}}"))
    }
}

@Test
func unrelatedEarlierClauseDoesNotSuppressStrongPlate() {
    let sanitizer = PrivacySanitizer()
    let result = sanitizer.sanitize("订单已完成。车辆京A12345已进入停车场。")

    #expect(result.text == "订单已完成。车辆{{PLATE}}已进入停车场。")
}

@Test
func japanesePlateRedactionPreservesPrecedingContext() {
    let sanitizer = PrivacySanitizer()
    let result = sanitizer.sanitize("通知：車両番号は品川 300 あ 12-34です。")

    #expect(result.text == "通知：車両番号は{{PLATE}}です。")
}

@Test
func sanitizerPassesFixedRegionalPlateRegressions() throws {
    let sanitizer = PrivacySanitizer()
    let fixtures = try loadNDJSON(
        PlatePositiveFixture.self,
        from: piiEvaluationURL("plate-positives.ndjson")
    )

    #expect(fixtures.count >= 20)
    for fixture in fixtures {
        let result = sanitizer.sanitize(fixture.text)
        #expect(result.redactions.contains { redaction in
            redaction.token == "{{PLATE}}" && String(fixture.text[redaction.range]) == fixture.value
        })
    }
}

@Test
func sanitizerDoesNotFlagFixedCleanRegressionsAsPlates() throws {
    let sanitizer = PrivacySanitizer()
    let fixtures = try loadNDJSON(
        CleanPIIFixture.self,
        from: piiEvaluationURL("clean-negatives.ndjson")
    )

    for fixture in fixtures {
        #expect(!sanitizer.sanitize(fixture.text).text.contains("{{PLATE}}"))
    }
}

@Test
func sanitizerRedactsEmailAndKeepsPlainText() {
    let sanitizer = PrivacySanitizer()
    let result = sanitizer.sanitize("发送至 someone@example.com 获取报告")
    // NSDataDetector may classify the address as a mailto link first; either
    // token is acceptable as long as the raw address is gone.
    #expect(result.text.contains("{{EMAIL}}") || result.text.contains("{{URL}}"))
    #expect(!result.text.contains("someone@example.com"))
    #expect(result.text.contains("获取报告"))
}

@Test
func sanitizerRedactsCompleteAmountsWithThousandsSeparators() {
    let sanitizer = PrivacySanitizer()
    let samples = [
        ("本月应还￥2,345.67，请按时还款。", "本月应还{{AMOUNT}}，请按时还款。"),
        ("账户到账2,345元。", "账户到账{{AMOUNT}}。"),
        ("优惠金额为 CNY 12，345.00。", "优惠金额为 {{AMOUNT}}。"),
        ("ご利用金額は￥1,234,567です。", "ご利用金額は{{AMOUNT}}です。"),
        ("請求額は2,345円です。", "請求額は{{AMOUNT}}です。"),
        ("The total is $2,345.00.", "The total is {{AMOUNT}}."),
        ("Payment received: 2,345.00 USD.", "Payment received: {{AMOUNT}}.")
    ]

    for (input, expected) in samples {
        #expect(sanitizer.sanitize(input).text == expected)
    }
}

@Test
func sanitizerDoesNotPartiallyRedactMalformedGroupedAmounts() {
    let sanitizer = PrivacySanitizer()
    let samples = [
        "账单金额为￥2,34，请人工核对。",
        "账单金额为2,34元，请人工核对。",
        "账单金额为￥1,2345，请人工核对。"
    ]

    for sample in samples {
        #expect(sanitizer.sanitize(sample).text == sample)
    }
}

@Test
func piiDetectionExpandsARecognizedAmountAcrossGroupedDigits() throws {
    let text = "本月应还￥2,345.67，请按时还款。"
    let partialRange = try #require(text.range(of: "￥2"))
    let detections = PIIDetectionPostprocessor.expandingGroupedAmounts(
        [PIIDetection(kind: .amount, range: partialRange)],
        in: text
    )

    let detection = try #require(detections.first)
    #expect(String(text[detection.range]) == "￥2,345.67")
}

@Test
func piiDetectionDoesNotExpandMalformedGroupedDigits() throws {
    let text = "本月应还￥2,34，请人工核对。"
    let partialRange = try #require(text.range(of: "￥2"))
    let detections = PIIDetectionPostprocessor.expandingGroupedAmounts(
        [PIIDetection(kind: .amount, range: partialRange)],
        in: text
    )

    let detection = try #require(detections.first)
    #expect(detection.range == partialRange)
}

@Test
func sanitizerDoesNotRedactOrdinaryNumericProductContent() {
    let sanitizer = PrivacySanitizer()
    let samples = [
        "本次购物获得320积分，当前积分余额为4260分。",
        "游戏2.8版本更新完成，新增地图并修复组队掉线问题。",
        "航班CA1234预计18:30起飞，请提前到达登机口。",
        "产品型号XG-2026已上新，首发版本包含三种颜色。",
        "超市满200减30活动今天开始。",
        "商品条码6901234567890123，请核对包装信息。",
        "客服工单20260711001已经处理完成。",
        "租房面积58平方米，靠近地铁2号线。",
        "游戏充值648档位赠送30%额外钻石。",
        "本次活动共有2,345名参与者。",
        "Score increased from 1,200 to 2,345 points."
    ]

    for sample in samples {
        #expect(sanitizer.sanitize(sample).text == sample)
    }
}

@Test
func sanitizerRedactsPlausibleCardButKeepsBarcode() {
    let sanitizer = PrivacySanitizer()

    let card = sanitizer.sanitize("银行卡号 4111 1111 1111 1111，请核对。")
    #expect(card.text.contains("{{CARD}}"))
    #expect(card.text.contains("4111 1111 1111 1111") == false)

    let barcode = "商品条码6901234567890123，请核对包装信息。"
    #expect(sanitizer.sanitize(barcode).text == barcode)
}

@Test
func modelCardDetectionCannotOverrideBarcodeGuard() {
    let barcode = "6901234567890123"
    let sanitizer = PrivacySanitizer(modelDetector: FakeDetector(kind: .card, needle: barcode))
    let text = "商品条码\(barcode)，请核对包装信息。"
    #expect(sanitizer.sanitize(text).text == text)
}

@Test
func modelPhoneDetectionCannotOverrideLongIdentifierGuard() {
    let identifier = "20260711001"
    let sanitizer = PrivacySanitizer(modelDetector: FakeDetector(kind: .phone, needle: identifier))
    let text = "客服工单\(identifier)已经处理完成。"
    #expect(sanitizer.sanitize(text).text == text)
}

@Test
func modelCodeDetectionRequiresAuthenticationContext() {
    let samples = [
        ("XG-2026", "产品代码 XG-2026 已更新，请同步货架信息。"),
        ("CA1234", "航班 CA1234 预计十八点起飞。"),
        ("E1007", "错误代码 E1007 表示库存同步尚未完成。"),
        ("S12", "游戏赛季 S12 将于周五开启。"),
        ("release-2026", "代码分支 release-2026 已完成合并。")
    ]

    for (value, text) in samples {
        let sanitizer = PrivacySanitizer(modelDetector: FakeDetector(kind: .code, needle: value))
        #expect(sanitizer.sanitize(text).text == text)
    }
}

@Test
func modelCodeDetectionKeepsPlausibleVerificationCodes() {
    let sanitizer = PrivacySanitizer(modelDetector: FakeDetector(kind: .code, needle: "A7K9Q2"))
    let result = sanitizer.sanitize("登录验证码为 A7K9Q2，十分钟内有效。")

    #expect(result.text.contains("{{CODE}}"))
    #expect(!result.text.contains("A7K9Q2"))
}

@Test
func modelOrderDetectionRequiresOrderContext() {
    let value = "AB-123-CD"
    let detector = FakeDetector(kind: .orderID, needle: value)

    #expect(PrivacySanitizer(modelDetector: detector).sanitize("Product model \(value) is now available.").text.contains("{{ORDER_ID}}") == false)
    #expect(PrivacySanitizer(modelDetector: detector).sanitize("Order number \(value) is ready for pickup.").text.contains("{{ORDER_ID}}"))
}

@Test
func modelAmountDetectionRequiresCurrencyOrAmountContext() {
    let value = "2,345"
    let detector = FakeDetector(kind: .amount, needle: value)

    let amount = PrivacySanitizer(modelDetector: detector).sanitize("账单金额为 \(value)，请核对。")
    #expect(amount.text.contains("{{AMOUNT}}"))

    let points = "本次活动获得 \(value) 积分。"
    #expect(PrivacySanitizer(modelDetector: detector).sanitize(points).text == points)

    let attendees = "イベントの参加者は\(value)人です。"
    #expect(PrivacySanitizer(modelDetector: detector).sanitize(attendees).text == attendees)

    let nearbyAmount = "支付￥2,345后获得2,346积分。"
    let nearbyDetector = FakeDetector(kind: .amount, needle: "2,346")
    #expect(
        PrivacySanitizer(modelDetector: nearbyDetector).sanitize(nearbyAmount).text
            == "支付{{AMOUNT}}后获得2,346积分。"
    )
}

@Test
func sanitizerUsesContextForCodesAndOrderIdentifiers() {
    let sanitizer = PrivacySanitizer()

    let code = sanitizer.sanitize("登录验证码是 482913，五分钟内有效。")
    #expect(code.text.contains("{{CODE}}"))
    #expect(code.text.contains("登录验证码是"))
    #expect(!code.text.contains("482913"))

    let order = sanitizer.sanitize("订单号：AB-1234567890 已完成付款。")
    #expect(order.text.contains("{{ORDER_ID}}"))
    #expect(order.text.contains("订单号："))
    #expect(!order.text.contains("AB-1234567890"))
}

@Test
func sanitizerDoesNotTreatOrganizationsOrPlacesAsNames() {
    let sanitizer = PrivacySanitizer()
    let sample = "Apple 将在北京发布新品，上海门店同步开售。"
    #expect(sanitizer.sanitize(sample).text == sample)
}

// MARK: - Model-track union

private struct FakeDetector: PIIDetecting {
    let kind: PIIKind
    let needle: String

    func detections(in text: String) -> [PIIDetection] {
        guard let range = text.range(of: needle) else {
            return []
        }
        return [PIIDetection(kind: kind, range: range)]
    }
}

@Test
func modelDetectionsUnionWithRules() {
    let sanitizer = PrivacySanitizer(modelDetector: FakeDetector(kind: .name, needle: "王小明"))
    let result = sanitizer.sanitize("王小明 的验证码是 482913")

    #expect(result.text.contains("{{NAME}}"))
    #expect(!result.text.contains("王小明"))
    #expect(result.text.contains("{{CODE}}"))
}

@Test
func overlappingModelDetectionDefersToTokenPriority() {
    // Model claims the digits are a NAME; the CODE rule matches the same
    // span. Priority list ranks CODE above NAME, so CODE wins.
    let sanitizer = PrivacySanitizer(modelDetector: FakeDetector(kind: .name, needle: "482913"))
    let result = sanitizer.sanitize("验证码 482913，请输入完成操作")

    #expect(result.text.contains("{{CODE}}"))
    #expect(!result.text.contains("{{NAME}}"))
}

@Test
func rulesStillApplyWhenModelDetectorReturnsNothing() {
    let sanitizer = PrivacySanitizer(modelDetector: FakeDetector(kind: .name, needle: "不存在的文本"))
    let result = sanitizer.sanitize("联系 13800138000 领取")
    #expect(result.text.contains("{{PHONE}}"))
}

// MARK: - Offset-aware encoding

@Test
func encodeWithOffsetsMapsPositionsBackToWords() throws {
    let tokens = [
        "[PAD]", "[UNK]", "[CLS]", "[SEP]",
        "un", "##aff", "##able", "code", "取", "件"
    ]
    var vocabulary: [String: Int32] = [:]
    for (index, token) in tokens.enumerated() {
        vocabulary[token] = Int32(index)
    }
    let tokenizer = try WordPieceTokenizer(
        vocabulary: vocabulary,
        configuration: WordPieceTokenizer.Configuration(maxSequenceLength: 12)
    )

    let text = "unaffable 取件 code"
    let encoded = tokenizer.encodeWithOffsets(text)

    // [CLS] un ##aff ##able 取 件 code [SEP] + padding
    #expect(encoded.inputIDs.prefix(8) == [2, 4, 5, 6, 8, 9, 7, 3])
    #expect(encoded.wordIndices[0] == nil)
    #expect(encoded.wordIndices[1] == 0)
    #expect(encoded.wordIndices[2] == 0)
    #expect(encoded.wordIndices[3] == 0)
    #expect(encoded.wordIndices[4] == 1)
    #expect(encoded.wordIndices[5] == 2)
    #expect(encoded.wordIndices[6] == 3)
    #expect(encoded.wordIndices[7] == nil)

    #expect(encoded.wordRanges.count == 4)
    #expect(String(text[encoded.wordRanges[0]]) == "unaffable")
    #expect(String(text[encoded.wordRanges[1]]) == "取")
    #expect(String(text[encoded.wordRanges[2]]) == "件")
    #expect(String(text[encoded.wordRanges[3]]) == "code")
}

@Test
func encodeWithOffsetsTruncatesWithoutBreakingAlignment() throws {
    let tokens = ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "a", "b", "c"]
    var vocabulary: [String: Int32] = [:]
    for (index, token) in tokens.enumerated() {
        vocabulary[token] = Int32(index)
    }
    let tokenizer = try WordPieceTokenizer(
        vocabulary: vocabulary,
        configuration: WordPieceTokenizer.Configuration(maxSequenceLength: 4)
    )

    let encoded = tokenizer.encodeWithOffsets("a b c")
    // Budget of 2 body positions: [CLS] a b [SEP]
    #expect(encoded.inputIDs == [2, 4, 5, 3])
    #expect(encoded.attentionMask == [1, 1, 1, 1])
    #expect(encoded.wordIndices == [nil, 0, 1, nil])
    #expect(encoded.wordRanges.count == 2)
}
#endif
