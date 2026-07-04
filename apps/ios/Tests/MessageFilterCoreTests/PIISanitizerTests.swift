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
    let result = sanitizer.sanitize("输入 482913 完成操作")

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
