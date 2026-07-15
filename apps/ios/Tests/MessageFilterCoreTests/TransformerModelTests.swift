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

// MARK: - BPETokenizer

private func makeBPETokenizer(maxSequenceLength: Int = 8) throws -> BPETokenizer {
    let json = """
    {
      "model": {
        "type": "BPE",
        "vocab": {
          "<pad>": 0, "<eos>": 1, "<bos>": 2, "<unk>": 3,
          "▁": 4,
          "h": 5, "e": 6, "l": 7, "o": 8,
          "w": 9, "r": 10, "d": 11,
          "▁h": 12, "▁he": 13, "▁hel": 14, "▁hell": 15, "▁hello": 16,
          "▁w": 17, "▁wo": 18, "▁wor": 19, "▁worl": 20, "▁world": 21
        },
        "merges": [
          ["▁", "h"], ["▁h", "e"], ["▁he", "l"], ["▁hel", "l"], ["▁hell", "o"],
          ["▁", "w"], ["▁w", "o"], ["▁wo", "r"], ["▁wor", "l"], ["▁worl", "d"]
        ],
        "byte_fallback": false,
        "unk_token": "<unk>"
      },
      "post_processor": {
        "special_tokens": {
          "<bos>": { "ids": [2], "tokens": ["<bos>"] },
          "<eos>": { "ids": [1], "tokens": ["<eos>"] }
        }
      }
    }
    """
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-bpe-\(UUID().uuidString).json")
    try json.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    return try BPETokenizer(
        tokenizerJSONURL: url,
        configuration: BPETokenizer.Configuration(maxSequenceLength: maxSequenceLength)
    )
}

@Test
func bpeTokenizerAppliesMetaspaceMergesAndSpecialTokens() throws {
    let tokenizer = try makeBPETokenizer()
    #expect(tokenizer.tokens("hello world") == ["▁hello", "▁world"])

    let encoded = tokenizer.tokenizeText("hello world")
    #expect(encoded.inputIDs == [2, 16, 21, 1, 0, 0, 0, 0])
    #expect(encoded.attentionMask == [1, 1, 1, 1, 0, 0, 0, 0])
}

@Test
func bpeTokenizerPreservesRepeatedSpacesAsMetaspaceTokens() throws {
    let tokenizer = try makeBPETokenizer()
    #expect(tokenizer.tokens("  hello") == ["▁", "▁hello"])
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
        action: .allow
    )
    SharedRuleStore.save([rule], defaults: defaults)

    let loaded = SharedRuleStore.load(defaults: defaults)
    #expect(loaded.count == 1)
    #expect(loaded.first?.id == rule.id)
    #expect(loaded.first?.sender?.pattern == "955")
    #expect(loaded.first?.action == .allow)
}

@Test
func legacyRuleTargetsMigrateToActions() throws {
    let allowJSON = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Bank","enabled":true,"priority":10,"sender":{"kind":"prefix","pattern":"955"},"targetLabelID":"finance.bank","createdAt":0}"#.utf8)
    let blockJSON = Data(#"{"id":"00000000-0000-0000-0000-000000000002","name":"Spam","enabled":true,"priority":10,"text":{"kind":"substring","pattern":"offer"},"targetLabelID":"promotion","createdAt":0}"#.utf8)

    #expect(try JSONDecoder().decode(CustomRule.self, from: allowJSON).action == .allow)
    #expect(try JSONDecoder().decode(CustomRule.self, from: blockJSON).action == .block)
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
func transformerManifestDecodesMmbertTrainerOutput() throws {
    let json = """
    {
      "version": "mmbert-0.1",
      "trainedAt": "2026-07-05T08:00:00.000Z",
      "algorithm": "supervised-sequence-classification",
      "backbone": "jhu-clsp/mmBERT-small",
      "languages": ["zh", "en", "ja"],
      "labels": ["spam", "promotion", "verification"],
      "maxSequenceLength": 96,
      "doLowerCase": false,
      "tokenizerKind": "bpe",
      "tokenizerArtifact": "SiftTransformerClassifier.tokenizer.json",
      "modelArtifact": "SiftTransformerClassifier.mlpackage",
      "sha256": "abc",
      "taxonomyHash": "def"
    }
    """
    let manifest = try JSONDecoder().decode(TransformerModelManifest.self, from: Data(json.utf8))
    #expect(manifest.version == "mmbert-0.1")
    #expect(manifest.tokenizerKind == "bpe")
    #expect(manifest.tokenizerArtifact == "SiftTransformerClassifier.tokenizer.json")
    #expect(manifest.vocabularyArtifact == nil)
}

@Test
func transformerLoaderReportsUnavailableWithoutBundledArtifacts() {
    #expect(!TransformerClassifierLoader.isAvailable(bundles: [.main], includeDownloaded: false))
}

@Test
func transformerModelStoreValidatesInstalledDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-transformer-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let vocabURL = directory.appendingPathComponent("SiftTransformerClassifier.vocab.txt")
    try "[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\n".write(to: vocabURL, atomically: true, encoding: .utf8)

    let modelURL = directory.appendingPathComponent("SiftTransformerClassifier.mlmodel")
    try Data("fake-model".utf8).write(to: modelURL)

    let manifest = TransformerModelManifest(
        version: "remote-0.1",
        trainedAt: "2026-07-07T08:00:00.000Z",
        algorithm: "supervised-sequence-classification",
        backbone: "jhu-clsp/mmBERT-small",
        languages: ["zh", "en", "ja"],
        labels: ["spam", "promotion"],
        maxSequenceLength: 8,
        doLowerCase: false,
        vocabularyArtifact: vocabURL.lastPathComponent,
        modelArtifact: modelURL.lastPathComponent,
        sha256: try TransformerModelStore.fileSHA256(at: modelURL),
        remoteArtifacts: [
            TransformerRemoteArtifact(
                path: vocabURL.lastPathComponent,
                sha256: try TransformerModelStore.fileSHA256(at: vocabURL),
                byteCount: Int64((try Data(contentsOf: vocabURL)).count)
            ),
            TransformerRemoteArtifact(
                path: modelURL.lastPathComponent,
                sha256: try TransformerModelStore.fileSHA256(at: modelURL),
                byteCount: Int64((try Data(contentsOf: modelURL)).count)
            )
        ],
        downloadBytes: 42
    )
    let manifestURL = TransformerModelStore.manifestURL(in: directory)
    try JSONEncoder().encode(manifest).write(to: manifestURL)

    let installed = try #require(TransformerModelStore.model(in: directory))
    #expect(installed.manifest.version == "remote-0.1")
    #expect(installed.tokenizerURL.lastPathComponent == vocabURL.lastPathComponent)
    #expect(installed.modelURL.lastPathComponent == modelURL.lastPathComponent)
}

@Test
func transformerModelStoreRejectsUnsafeArtifactPaths() {
    #expect(TransformerModelStore.isSafeRelativePath("SiftTransformerClassifier.mlpackage/Data/model.mlmodel"))
    #expect(!TransformerModelStore.isSafeRelativePath("../model.mlpackage"))
    #expect(!TransformerModelStore.isSafeRelativePath("/tmp/model.mlpackage"))
}
#endif
