#if canImport(Testing)
import Foundation
import MessageFilterCore
import Testing

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
        "游戏充值648档位赠送30%额外钻石。"
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
