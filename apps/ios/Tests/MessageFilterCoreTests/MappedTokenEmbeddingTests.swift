import Foundation
import Testing
@testable import MessageFilterCore

private func embeddingFixture(scaleBytes: Int) -> Data {
    var data = Data("SIFTEMB1".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    for value in [1, 2, 4, 2, scaleBytes, 2 + 2 * scaleBytes] { append(UInt32(value)) }
    data.append(Data(repeating: 0, count: 32))
    for (packed, scales) in [([UInt8(0xf8), 0x70], [Float(0.5), 2]), ([0x21, 0xe9], [1, 0.25])] {
        data.append(contentsOf: packed)
        for scale in scales {
            if scaleBytes == 4 { append(scale.bitPattern) }
            else { append(Float16(scale).bitPattern) }
        }
    }
    return data
}

private func withEmbeddingFile(_ data: Data, body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".siftemb")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    try body(url)
}

@Test(arguments: [2, 4])
func mappedEmbeddingDecodesSignedNibblesScalesAndRepeatedRows(scaleBytes: Int) throws {
    try withEmbeddingFile(embeddingFixture(scaleBytes: scaleBytes)) { url in
        let mapped = try MappedTokenEmbedding(url: url)
        #expect(mapped.width == 4)
        #expect(mapped.vocabularySize == 2)
        var values = [Float](repeating: .nan, count: 12)
        try values.withUnsafeMutableBufferPointer { try mapped.decode(tokenIDs: [1, 0, 1], into: $0) }
        #expect(values == [1, 2, -1.75, -0.5, -4, -0.5, 0, 14, 1, 2, -1.75, -0.5])
        // Unlinking an old installed artifact must not invalidate an in-flight mapping.
        try FileManager.default.removeItem(at: url)
        try values.withUnsafeMutableBufferPointer { try mapped.decode(tokenIDs: [0, 0, 0], into: $0) }
        #expect(values == Array(repeating: [Float(-4), -0.5, 0, 14], count: 3).flatMap { $0 })
    }
}

@Test
func mappedEmbeddingRejectsInvalidHeadersAndTruncation() throws {
    let valid = embeddingFixture(scaleBytes: 4)
    var badMagic = valid; badMagic[0] = 0
    var badVersion = valid; badVersion[8] = 2
    var badBlock = valid; badBlock[20] = 0
    var badScale = valid; badScale[24] = 3
    var badStride = valid; badStride[28] = 0
    var badReserved = valid; badReserved[32] = 1
    var hugeWidth = valid; hugeWidth[19] = 0xff
    for data in [Data(), Data(valid.prefix(63)), Data(valid.dropLast()), valid + Data([0]),
                 badMagic, badVersion, badBlock, badScale, badStride, badReserved, hugeWidth] {
        try withEmbeddingFile(data) { url in
            #expect(throws: MappedTokenEmbedding.ReadError.self) { try MappedTokenEmbedding(url: url) }
        }
    }
}

@Test
func mappedEmbeddingRejectsInvalidTokenIDsAndOutputBuffer() throws {
    try withEmbeddingFile(embeddingFixture(scaleBytes: 4)) { url in
        let mapped = try MappedTokenEmbedding(url: url)
        var values = [Float](repeating: 99, count: 4)
        for ids: [Int32] in [[-1], [2], [Int32.max], [0, 1]] {
            #expect(throws: MappedTokenEmbedding.ReadError.self) {
                try values.withUnsafeMutableBufferPointer { try mapped.decode(tokenIDs: ids, into: $0) }
            }
            #expect(values == [99, 99, 99, 99])
        }
    }
}

@Test(arguments: [2, 4])
func mappedEmbeddingRejectsNonFiniteScales(scaleBytes: Int) throws {
    var data = embeddingFixture(scaleBytes: scaleBytes)
    let offset = 64 + 2
    if scaleBytes == 4 { data.replaceSubrange(offset..<(offset + 4), with: [0, 0, 0x80, 0x7f]) }
    else { data.replaceSubrange(offset..<(offset + 2), with: [0, 0x7c]) }
    try withEmbeddingFile(data) { url in
        let mapped = try MappedTokenEmbedding(url: url)
        var values = [Float](repeating: 0, count: 4)
        #expect(throws: MappedTokenEmbedding.ReadError.self) {
            try values.withUnsafeMutableBufferPointer { try mapped.decode(tokenIDs: [0], into: $0) }
        }
    }
}

private func mappedManifest(build: Int = 22, sequence: Int = 5, includesEmbedding: Bool = true,
                            modelHash: String = "test", embeddingHash: String = "test") -> TransformerModelManifest {
    TransformerModelManifest(
        releaseSequence: sequence, modelABI: MappedTokenEmbedding.modelABI, minimumAppBuild: build,
        version: "mapped-test", trainedAt: "2026-09-05", algorithm: "teacher-student-distillation",
        backbone: "mmbert", languages: ["zh", "en", "ja"], labels: ["spam"], maxSequenceLength: 96,
        doLowerCase: false, tokenizerKind: "bpe", tokenizerArtifact: "tokenizer.siftbpe",
        modelArtifact: "SiftSignalModel.mlpackage", sha256: modelHash, taxonomyHash: "test",
        remoteArtifacts: includesEmbedding ? [TransformerRemoteArtifact(
            path: "SiftSignalModel.mlpackage/" + MappedTokenEmbedding.relativePath,
            sha256: embeddingHash, byteCount: 84
        )] : [], downloadBytes: 84,
        distillation: TransformerDistillationProvenance(
            teacherCheckpointSHA256: String(repeating: "a", count: 64), teacherLayers: 22,
            studentLayers: 12, temperature: 2, distillAlpha: 0.7
        )
    )
}

@Test
func mappedEmbeddingReleaseRequiresNewRuntimeAndSignedArtifactEntry() {
    #expect(TransformerSignalReleaseContract.accepts(mappedManifest()))
    #expect(!TransformerSignalReleaseContract.accepts(mappedManifest(build: 21)))
    #expect(!TransformerSignalReleaseContract.accepts(mappedManifest(sequence: 4)))
    #expect(!TransformerSignalReleaseContract.accepts(mappedManifest(includesEmbedding: false)))
}

@Test
func mappedEmbeddingIsBoundToModelIdentityAndRequiredForDiscovery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = directory.appendingPathComponent("SiftSignalModel.mlpackage")
    let embedding = package.appendingPathComponent(MappedTokenEmbedding.relativePath)
    try FileManager.default.createDirectory(at: embedding.deletingLastPathComponent(), withIntermediateDirectories: true)
    try embeddingFixture(scaleBytes: 4).write(to: embedding)
    let originalHash = try TransformerModelStore.directorySHA256(at: package)
    let manifest = mappedManifest(modelHash: originalHash, embeddingHash: try TransformerModelStore.fileSHA256(at: embedding))
    try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("SiftSignalModel.manifest.json"))
    try Data([0]).write(to: directory.appendingPathComponent("tokenizer.siftbpe"))
    let installed = TransformerModelStore.model(in: directory, validateChecksums: false)
    #expect(installed?.embeddingURL == embedding)
    #expect(TransformerModelStore.model(in: directory, validateChecksums: true) != nil)
    var changed = embeddingFixture(scaleBytes: 4); changed[64] ^= 1
    try changed.write(to: embedding, options: .atomic)
    #expect(try TransformerModelStore.directorySHA256(at: package) != originalHash)
    #expect(TransformerModelStore.model(in: directory, validateChecksums: true) == nil)
    try FileManager.default.removeItem(at: embedding)
    #expect(TransformerModelStore.model(in: directory, validateChecksums: false) == nil)
}
