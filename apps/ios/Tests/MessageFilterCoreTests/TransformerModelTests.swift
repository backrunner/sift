#if canImport(Testing)
import Foundation
import MessageFilterCore
import Testing

#if canImport(CryptoKit)
import CryptoKit
#endif

private final class ClassicInvocationCountingClassifier: MessageClassifier, @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCountStorage = 0
    let decision: ClassificationDecision

    init(decision: ClassificationDecision) {
        self.decision = decision
    }

    var invocationCount: Int {
        lock.withLock { invocationCountStorage }
    }

    func classify(sender: String?, body: String) -> ClassificationDecision {
        lock.withLock { invocationCountStorage += 1 }
        return decision
    }
}

@Test
func cascadingClassifierTreatsModelAbstentionAsTerminal() {
    let primary = ClassicInvocationCountingClassifier(
        decision: ModelOutputContract.abstentionDecision(confidence: 0.99)
    )
    let fallback = ClassicInvocationCountingClassifier(
        decision: ClassificationDecision(
            labelID: "promotion",
            labelTitle: "Promotion",
            groupID: "promotion",
            groupTitle: "Promotion",
            confidence: 1,
            systemAction: .promotion,
            source: .model
        )
    )

    let classifier = CascadingClassifier(primary: primary, fallback: fallback)
    let result = ClassificationPipeline(classifier: classifier)
        .classify(sender: nil, body: "private conversation", rules: [])

    #expect(result.labelID == ModelOutputContract.abstainLabel)
    #expect(result.systemAction == .none)
    #expect(result.source == .fallback)
    #expect(primary.invocationCount == 1)
    #expect(fallback.invocationCount == 0)
}

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

// MARK: - Compact BPETokenizer

@Test
func compactBPETokenizerUsesMemoryMappedIndexes() throws {
    let tokens = ["<pad>", "<eos>", "<bos>", "<unk>", "▁", "h", "i", "▁h", "▁hi"]
    let merges: [(first: UInt32, second: UInt32, result: UInt32)] = [
        (4, 5, 7),
        (7, 6, 8),
    ]
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-compact-bpe-\(UUID().uuidString).siftbpe")
    defer { try? FileManager.default.removeItem(at: url) }
    try compactTokenizerData(tokens: tokens, merges: merges).write(to: url)

    let tokenizer = try BPETokenizer(
        tokenizerURL: url,
        configuration: BPETokenizer.Configuration(maxSequenceLength: 6)
    )

    #expect(tokenizer.tokens("hi") == ["▁hi"])
    #expect(tokenizer.tokens("  hi") == ["▁", "▁hi"])
    #expect(tokenizer.tokenizeText("hi").inputIDs == [2, 8, 1, 0, 0, 0])
}

@Test
func compactBPETokenizerRejectsOversizedBlobLengthWithoutTrapping() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-invalid-compact-bpe-\(UUID().uuidString).siftbpe")
    defer { try? FileManager.default.removeItem(at: url) }

    var data = compactTokenizerData(
        tokens: ["<pad>", "<eos>", "<bos>", "<unk>"],
        merges: []
    )
    data.replaceSubrange(40..<48, with: withUnsafeBytes(of: UInt64.max.littleEndian) { Data($0) })
    try data.write(to: url)

    #expect(throws: BPETokenizer.TokenizerError.invalidCompactArtifact) {
        try BPETokenizer(tokenizerURL: url)
    }
}

private func compactTokenizerData(
    tokens: [String],
    merges: [(first: UInt32, second: UInt32, result: UInt32)]
) -> Data {
    var tokenBlob = Data()
    var tokenRecords: [(offset: UInt32, length: UInt32)] = []
    var hashRecords: [(hash: UInt64, id: UInt32)] = []
    for (id, token) in tokens.enumerated() {
        let bytes = Data(token.utf8)
        tokenRecords.append((UInt32(tokenBlob.count), UInt32(bytes.count)))
        tokenBlob.append(bytes)
        hashRecords.append((compactTokenizerHash(Array(bytes)), UInt32(id)))
    }
    hashRecords.sort { lhs, rhs in
        lhs.hash == rhs.hash ? lhs.id < rhs.id : lhs.hash < rhs.hash
    }

    var data = Data("SIFTBPE1".utf8)
    data.appendLittleEndian(UInt32(1))
    data.appendLittleEndian(UInt32(0))
    data.appendLittleEndian(UInt32(tokens.count))
    data.appendLittleEndian(UInt32(merges.count))
    data.appendLittleEndian(UInt32(3))
    data.appendLittleEndian(UInt32(2))
    data.appendLittleEndian(UInt32(1))
    data.appendLittleEndian(UInt32(0))
    data.appendLittleEndian(UInt64(tokenBlob.count))
    for record in tokenRecords {
        data.appendLittleEndian(record.offset)
        data.appendLittleEndian(record.length)
    }
    for record in hashRecords {
        data.appendLittleEndian(record.hash)
        data.appendLittleEndian(record.id)
        data.appendLittleEndian(UInt32(0))
    }
    for (rank, merge) in merges.enumerated().sorted(by: {
        compactPairKey($0.element.first, $0.element.second)
            < compactPairKey($1.element.first, $1.element.second)
    }) {
        data.appendLittleEndian(compactPairKey(merge.first, merge.second))
        data.appendLittleEndian(UInt32(rank))
        data.appendLittleEndian(merge.result)
    }
    data.append(tokenBlob)
    return data
}

private func compactPairKey(_ first: UInt32, _ second: UInt32) -> UInt64 {
    UInt64(first) << 32 | UInt64(second)
}

private func compactTokenizerHash(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return hash
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { bytes in
            append(contentsOf: bytes)
        }
    }
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

@Test
func transformerDeviceSupportUsesA12AsTheMinimumGate() {
    #expect(!TransformerDeviceSupport.evaluate(hardwareIdentifier: "iPhone10,6").isSupported)
    #expect(TransformerDeviceSupport.evaluate(hardwareIdentifier: "iPhone11,8").isSupported)
    #expect(!TransformerDeviceSupport.evaluate(hardwareIdentifier: "iPad7,6").isSupported)
    #expect(TransformerDeviceSupport.evaluate(hardwareIdentifier: "iPad8,1").isSupported)
    #expect(!TransformerDeviceSupport.evaluate(hardwareIdentifier: "iPod9,1").isSupported)
    #expect(!TransformerDeviceSupport.evaluate(hardwareIdentifier: "futureDevice1,1").isSupported)
}

@Test
func transformerV3ReservesAnAbstainOutputWithoutChangingTaxonomy() {
    #expect(TransformerManifestVerifier.supportedModelABIs.contains("sift-mmbert-v3"))
    #expect(TransformerModelContract.isAbstainLabel("__sift_abstain__"))
    #expect(SiftTaxonomy.leaf(id: TransformerModelContract.abstainLabel) == nil)
}

// MARK: - TransformerModelManifest

@Test
func piiManifestDecodesCurrentTrainerOutput() throws {
    let json = """
    {
      "version": "pii-boundary-v5",
      "trainedAt": "2026-07-11T07:56:19.924Z",
      "algorithm": "token-classification-pii",
      "backbone": "distilbert-base-multilingual-cased",
      "languages": ["zh", "en", "ja", "multi"],
      "labels": ["O", "PHONE", "EMAIL"],
      "maxSequenceLength": 96,
      "doLowerCase": false,
      "vocabularyArtifact": "SiftPIIDetector.vocab.txt",
      "modelArtifact": "SiftPIIDetector.mlpackage",
      "sha256": "abc"
    }
    """
    let manifest = try JSONDecoder().decode(PIIModelManifest.self, from: Data(json.utf8))
    #expect(manifest.version == "pii-boundary-v5")
    #expect(manifest.vocabularyArtifact == "SiftPIIDetector.vocab.txt")
    #expect(manifest.labels == ["O", "PHONE", "EMAIL"])
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
      "tokenizerArtifact": "SiftTransformerClassifier.tokenizer.siftbpe",
      "modelArtifact": "SiftTransformerClassifier.mlpackage",
      "sha256": "abc",
      "taxonomyHash": "def",
      "remoteArtifacts": [
        {
          "path": "SiftTransformerClassifier.tokenizer.siftbpe",
          "sha256": "ghi",
          "byteCount": 123
        },
        {
          "path": "SiftTransformerClassifier.mlpackage/Data/model.mlmodel",
          "sha256": "jkl",
          "byteCount": 456
        }
      ],
      "downloadBytes": 579
    }
    """
    let manifest = try JSONDecoder().decode(TransformerModelManifest.self, from: Data(json.utf8))
    #expect(manifest.version == "mmbert-0.1")
    #expect(manifest.tokenizerKind == "bpe")
    #expect(manifest.tokenizerArtifact == "SiftTransformerClassifier.tokenizer.siftbpe")
    #expect(manifest.remoteArtifacts.count == 2)
    #expect(manifest.downloadBytes == 579)
}

@Test
func transformerModelStoreValidatesInstalledDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-transformer-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let tokenizerURL = directory.appendingPathComponent("SiftTransformerClassifier.tokenizer.siftbpe")
    let tokenizerData = compactTokenizerData(
        tokens: ["<pad>", "<eos>", "<bos>", "<unk>", "▁", "h", "i", "▁h", "▁hi"],
        merges: [(4, 5, 7), (7, 6, 8)]
    )
    try tokenizerData.write(to: tokenizerURL)

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
        tokenizerKind: "bpe",
        tokenizerArtifact: tokenizerURL.lastPathComponent,
        modelArtifact: modelURL.lastPathComponent,
        sha256: try TransformerModelStore.fileSHA256(at: modelURL),
        taxonomyHash: "taxonomy-hash",
        remoteArtifacts: [
            TransformerRemoteArtifact(
                path: tokenizerURL.lastPathComponent,
                sha256: try TransformerModelStore.fileSHA256(at: tokenizerURL),
                byteCount: Int64(tokenizerData.count)
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
    #expect(installed.tokenizerURL.lastPathComponent == tokenizerURL.lastPathComponent)
    #expect(installed.modelURL.lastPathComponent == modelURL.lastPathComponent)
}

@Test
func transformerModelStoreCountsInstalledFileBytes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-transformer-size-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let nestedDirectory = directory.appendingPathComponent("Model", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    try Data(repeating: 0xA5, count: 1_024).write(
        to: directory.appendingPathComponent("tokenizer.siftbpe")
    )
    try Data(repeating: 0x5A, count: 2_048).write(
        to: nestedDirectory.appendingPathComponent("weights.bin")
    )

    #expect(try TransformerModelStore.directoryByteCount(at: directory) == 3_072)
}

@Test
func transformerModelStoreRejectsUnsafeArtifactPaths() {
    #expect(TransformerModelStore.isSafeRelativePath("SiftTransformerClassifier.mlpackage/Data/model.mlmodel"))
    #expect(!TransformerModelStore.isSafeRelativePath("../model.mlpackage"))
    #expect(!TransformerModelStore.isSafeRelativePath("/tmp/model.mlpackage"))
}

@Test
func transformerResumeDataPathRequiresCanonicalSHA256() {
    #expect(TransformerModelStore.isSHA256(String(repeating: "a", count: 64)))
    #expect(!TransformerModelStore.isSHA256(String(repeating: "A", count: 64)))
    #expect(!TransformerModelStore.isSHA256("../resume"))
    #expect(TransformerModelStore.downloadResumeDataURL(artifactSHA256: "../resume") == nil)
}

#if canImport(CryptoKit)
@Test
func transformerModelStoreStreamsLargeFileHashes() throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-transformer-hash-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let data = Data(repeating: 0xA5, count: 2_500_000)
    try data.write(to: fileURL)
    let expected = SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()

    #expect(try TransformerModelStore.fileSHA256(at: fileURL) == expected)
}

@Test
func transformerChannelManifestRequiresValidEd25519Signature() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let unsigned = TransformerChannelManifestV2(
        releaseSequence: 9,
        releaseID: "mmbert-boundary-v9",
        releaseManifestURL: "https://example.com/models/releases/mmbert-boundary-v9/manifest.json",
        releaseManifestSHA256: "manifest-sha",
        modelABI: "sift-mmbert-v2",
        minimumAppBuild: 7,
        maximumAppBuild: 20,
        minimumOSVersion: "18.0",
        downloadBytes: 120_000_000,
        keyID: "release-2026"
    )
    let signature = try privateKey.signature(for: unsigned.canonicalPayload()).base64EncodedString()
    let signed = TransformerChannelManifestV2(
        releaseSequence: unsigned.releaseSequence,
        releaseID: unsigned.releaseID,
        releaseManifestURL: unsigned.releaseManifestURL,
        releaseManifestSHA256: unsigned.releaseManifestSHA256,
        modelABI: unsigned.modelABI,
        minimumAppBuild: unsigned.minimumAppBuild,
        maximumAppBuild: unsigned.maximumAppBuild,
        minimumOSVersion: unsigned.minimumOSVersion,
        downloadBytes: unsigned.downloadBytes,
        keyID: unsigned.keyID,
        signature: signature
    )
    let verifier = TransformerManifestVerifier(publicKeys: [
        unsigned.keyID: privateKey.publicKey.rawRepresentation.base64EncodedString()
    ])

    try verifier.verifySignature(of: signed)
    #expect(throws: ManifestVerificationError.invalidSignature) {
        let changed = TransformerChannelManifestV2(
            releaseSequence: 10,
            releaseID: signed.releaseID,
            releaseManifestURL: signed.releaseManifestURL,
            releaseManifestSHA256: signed.releaseManifestSHA256,
            modelABI: signed.modelABI,
            minimumAppBuild: signed.minimumAppBuild,
            maximumAppBuild: signed.maximumAppBuild,
            minimumOSVersion: signed.minimumOSVersion,
            downloadBytes: signed.downloadBytes,
            keyID: signed.keyID,
            signature: signature
        )
        try verifier.verifySignature(of: changed)
    }
}

@Test
func pythonOpenSSLManifestV2SignaturesVerifyInSwift() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixtureURL = repositoryRoot
        .appendingPathComponent("tools/transformer-trainer/tests/fixtures/manifest_v2_ed25519.json")
    let data = try Data(contentsOf: fixtureURL)
    let fixture = try JSONDecoder().decode(ManifestV2InteropFixture.self, from: data)
    let verifier = TransformerManifestVerifier(publicKeys: [
        fixture.channel.keyID: fixture.publicKeyBase64
    ])

    try verifier.verifySignature(of: fixture.channel)
    try verifier.verifySignature(of: fixture.release)
}

private struct ManifestV2InteropFixture: Decodable {
    let publicKeyBase64: String
    let channel: TransformerChannelManifestV2
    let release: TransformerReleaseManifestV2
}

@Test
func transformerChannelCompatibilityChecksBuildOSABIAndRollback() {
    let verifier = TransformerManifestVerifier(publicKeys: [:])
    let channel = TransformerChannelManifestV2(
        releaseSequence: 9,
        releaseID: "mmbert-boundary-v9",
        releaseManifestURL: "https://example.com/manifest.json",
        releaseManifestSHA256: "sha",
        modelABI: "sift-mmbert-v2",
        minimumAppBuild: 7,
        maximumAppBuild: 20,
        minimumOSVersion: "18.1",
        keyID: "key"
    )

    #expect(verifier.compatibility(
        of: channel,
        appBuild: 7,
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 18, minorVersion: 1, patchVersion: 0),
        currentReleaseSequence: 8
    ) == .compatible)
    #expect(verifier.compatibility(
        of: channel,
        appBuild: 6,
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 18, minorVersion: 1, patchVersion: 0),
        currentReleaseSequence: 8
    ) == .appBuildTooOld)
    #expect(verifier.compatibility(
        of: channel,
        appBuild: 7,
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 18, minorVersion: 0, patchVersion: 0),
        currentReleaseSequence: 8
    ) == .operatingSystemTooOld)
    #expect(verifier.compatibility(
        of: channel,
        appBuild: 7,
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 18, minorVersion: 1, patchVersion: 0),
        currentReleaseSequence: 10
    ) == .releaseRollback)
}
#endif
#endif
