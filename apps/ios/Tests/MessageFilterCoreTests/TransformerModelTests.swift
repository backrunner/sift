#if canImport(Testing)
import Foundation
import MessageFilterCore
import Testing

// MARK: - WordPieceTokenizer

private func makeTokenizer(
    doLowerCase: Bool = false,
    maxSequenceLength: Int = 12
) throws -> WordPieceTokenizer {
    let tokens = [
        "[PAD]", "[UNK]", "[CLS]", "[SEP]",
        "un", "##aff", "##able", "##ing",
        "run", "verification", "code",
        "取", "件", "码", "验", "证",
        "!", ",", "。", "123", "##456"
    ]
    var vocabulary: [String: Int32] = [:]
    for (index, token) in tokens.enumerated() {
        vocabulary[token] = Int32(index)
    }
    return try WordPieceTokenizer(
        vocabulary: vocabulary,
        configuration: WordPieceTokenizer.Configuration(
            doLowerCase: doLowerCase,
            maxSequenceLength: maxSequenceLength
        )
    )
}

@Test
func wordPieceSplitsIntoGreedyLongestSubwords() throws {
    let tokenizer = try makeTokenizer()
    #expect(tokenizer.tokenize("unaffable") == ["un", "##aff", "##able"])
    #expect(tokenizer.tokenize("runing") == ["run", "##ing"])
}

@Test
func wordPieceIsolatesCJKCharactersAndPunctuation() throws {
    let tokenizer = try makeTokenizer()
    #expect(tokenizer.tokenize("取件码!") == ["取", "件", "码", "!"])
    #expect(tokenizer.tokenize("验证code") == ["验", "证", "code"])
}

@Test
func wordPieceMapsUnknownWordsToUnk() throws {
    let tokenizer = try makeTokenizer()
    #expect(tokenizer.tokenize("zzz") == ["[UNK]"])
}

@Test
func lowercasingAppliesWhenConfigured() throws {
    let tokenizer = try makeTokenizer(doLowerCase: true)
    #expect(tokenizer.tokenize("Verification CODE") == ["verification", "code"])
}

@Test
func encodeAddsSpecialsPadsAndMasks() throws {
    let tokenizer = try makeTokenizer(maxSequenceLength: 8)
    let encoded = tokenizer.encode("取件码")

    #expect(encoded.inputIDs.count == 8)
    #expect(encoded.attentionMask.count == 8)
    // [CLS] 取 件 码 [SEP] [PAD] [PAD] [PAD]
    #expect(encoded.inputIDs[0] == 2)
    #expect(encoded.inputIDs[4] == 3)
    #expect(encoded.inputIDs[5] == 0)
    #expect(encoded.attentionMask == [1, 1, 1, 1, 1, 0, 0, 0])
}

@Test
func encodeTruncatesLongInputsKeepingSpecialTokens() throws {
    let tokenizer = try makeTokenizer(maxSequenceLength: 6)
    let encoded = tokenizer.encode("取件码验证取件码验证取件码")

    #expect(encoded.inputIDs.count == 6)
    #expect(encoded.inputIDs.first == 2)
    #expect(encoded.inputIDs.last == 3)
    #expect(encoded.attentionMask.allSatisfy { $0 == 1 })
}

@Test
func tokenizerRequiresSpecialTokens() {
    #expect(throws: WordPieceTokenizer.TokenizerError.missingSpecialToken("[CLS]")) {
        _ = try WordPieceTokenizer(vocabulary: ["[PAD]": 0, "[UNK]": 1, "[SEP]": 2, "hello": 3])
    }
}

@Test
func vocabularyFileKeepsIdAlignmentAroundBlankLines() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-vocab-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }

    // Blank line in the middle must consume id 5 without shifting later ids;
    // the trailing newline must not consume an id.
    let lines = ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "hello", "", "world"]
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

    let tokenizer = try WordPieceTokenizer(
        vocabularyFileURL: url,
        configuration: WordPieceTokenizer.Configuration(maxSequenceLength: 8)
    )
    let encoded = tokenizer.encode("world hello")
    // [CLS]=2, world=6, hello=4, [SEP]=3, padding=0
    #expect(Array(encoded.inputIDs.prefix(4)) == [2, 6, 4, 3])
}

// MARK: - SharedRuleStore

@Test
func sharedRuleStoreRoundTripsRules() throws {
    let suiteName = "SiftTests.sharedRules.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(SharedRuleStore.load(defaults: defaults).isEmpty)

    let rule = CustomRule(
        name: "Bank sender",
        priority: 40,
        sender: SenderMatcher(kind: .prefix, pattern: "955"),
        targetLabelID: "finance.bank"
    )
    SharedRuleStore.save([rule], defaults: defaults)

    let loaded = SharedRuleStore.load(defaults: defaults)
    #expect(loaded.count == 1)
    #expect(loaded.first?.id == rule.id)
    #expect(loaded.first?.sender?.pattern == "955")
    #expect(loaded.first?.targetLabelID == "finance.bank")
}

// MARK: - ModelVariant / ModelSelectionStore

@Test
func modelSelectionRoundTripsThroughDefaults() throws {
    let suiteName = "SiftTests.modelSelection.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(ModelSelectionStore.load(defaults: defaults) == .classic)

    ModelSelectionStore.save(.transformer, defaults: defaults)
    #expect(ModelSelectionStore.load(defaults: defaults) == .transformer)

    ModelSelectionStore.save(.classic, defaults: defaults)
    #expect(ModelSelectionStore.load(defaults: defaults) == .classic)
}

@Test
func transformerVariantDisablesLocalPersonalization() {
    #expect(ModelVariant.classic.supportsLocalPersonalization)
    #expect(!ModelVariant.transformer.supportsLocalPersonalization)
}

// MARK: - TransformerModelManifest

@Test
func transformerManifestDecodesTrainerOutput() throws {
    let json = """
    {
      "version": "setfit-0.1",
      "trainedAt": "2026-07-04T08:00:00.000Z",
      "algorithm": "setfit-sentence-transformer",
      "backbone": "sentence-transformers/distiluse-base-multilingual-cased-v2",
      "languages": ["zh", "en", "es"],
      "labels": ["spam", "promotion", "verification"],
      "maxSequenceLength": 96,
      "doLowerCase": false,
      "vocabularyArtifact": "SiftTransformerClassifier.vocab.txt",
      "modelArtifact": "SiftTransformerClassifier.mlpackage",
      "sha256": "abc",
      "taxonomyHash": "def"
    }
    """
    let manifest = try JSONDecoder().decode(TransformerModelManifest.self, from: Data(json.utf8))
    #expect(manifest.version == "setfit-0.1")
    #expect(manifest.labels.count == 3)
    #expect(manifest.maxSequenceLength == 96)
    #expect(!manifest.doLowerCase)
    #expect(manifest.languages.contains("zh"))
}

@Test
func transformerLoaderReportsUnavailableWithoutBundledArtifacts() {
    #expect(!TransformerClassifierLoader.isAvailable(bundles: [.main]))
}
#endif
