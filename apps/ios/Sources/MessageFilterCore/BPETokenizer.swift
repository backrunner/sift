import Foundation

/// Memory-mapped BPE tokenizer used by the downloadable mmBERT model.
public struct BPETokenizer: TextTokenizing, Sendable {
    public struct Configuration: Hashable, Sendable {
        public var maxSequenceLength: Int

        public init(maxSequenceLength: Int = 96) {
            self.maxSequenceLength = maxSequenceLength
        }
    }

    public enum TokenizerError: Error, Hashable {
        case invalidCompactArtifact
        case unsupportedCompactVersion(UInt32)
    }

    private struct MergeValue: Sendable {
        let rank: Int
        let resultID: Int32
    }

    private struct CompactStorage: Sendable {
        static let magic = Array("SIFTBPE1".utf8)
        static let headerSize = 48
        static let tokenRecordSize = 8
        static let hashRecordSize = 16
        static let mergeRecordSize = 16

        let data: Data
        let vocabularyCount: Int
        let mergeCount: Int
        let tokenRecordsOffset: Int
        let hashRecordsOffset: Int
        let mergeRecordsOffset: Int
        let tokenBlobOffset: Int

        init(data: Data) throws {
            guard
                data.count >= Self.headerSize,
                Array(data.prefix(Self.magic.count)) == Self.magic
            else {
                throw TokenizerError.invalidCompactArtifact
            }

            let version = Self.readUInt32(data, at: 8)
            guard version == 1 else {
                throw TokenizerError.unsupportedCompactVersion(version)
            }

            let vocabularyCount = Int(Self.readUInt32(data, at: 16))
            let mergeCount = Int(Self.readUInt32(data, at: 20))
            guard let tokenBlobSize = Int(exactly: Self.readUInt64(data, at: 40)) else {
                throw TokenizerError.invalidCompactArtifact
            }
            let tokenRecordsOffset = Self.headerSize
            let hashRecordsOffset = tokenRecordsOffset + vocabularyCount * Self.tokenRecordSize
            let mergeRecordsOffset = hashRecordsOffset + vocabularyCount * Self.hashRecordSize
            let tokenBlobOffset = mergeRecordsOffset + mergeCount * Self.mergeRecordSize

            guard
                vocabularyCount > 0,
                tokenBlobOffset <= data.count,
                tokenBlobSize == data.count - tokenBlobOffset
            else {
                throw TokenizerError.invalidCompactArtifact
            }

            let specialTokenIDs = [
                Self.readUInt32(data, at: 24),
                Self.readUInt32(data, at: 28),
                Self.readUInt32(data, at: 32),
                Self.readUInt32(data, at: 36),
            ]
            guard specialTokenIDs.allSatisfy({ $0 < UInt32(vocabularyCount) }) else {
                throw TokenizerError.invalidCompactArtifact
            }

            self.data = data
            self.vocabularyCount = vocabularyCount
            self.mergeCount = mergeCount
            self.tokenRecordsOffset = tokenRecordsOffset
            self.hashRecordsOffset = hashRecordsOffset
            self.mergeRecordsOffset = mergeRecordsOffset
            self.tokenBlobOffset = tokenBlobOffset
        }

        var byteFallback: Bool {
            Self.readUInt32(data, at: 12) & 1 == 1
        }

        var unknownID: Int32 { Int32(bitPattern: Self.readUInt32(data, at: 24)) }
        var beginID: Int32 { Int32(bitPattern: Self.readUInt32(data, at: 28)) }
        var endID: Int32 { Int32(bitPattern: Self.readUInt32(data, at: 32)) }
        var paddingID: Int32 { Int32(bitPattern: Self.readUInt32(data, at: 36)) }

        func tokenID(for token: String) -> Int32? {
            let bytes = Array(token.utf8)
            let hash = BPETokenizer.fnv1a64(bytes)
            var lower = 0
            var upper = vocabularyCount
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if hashValue(at: middle) < hash {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }

            var index = lower
            while index < vocabularyCount, hashValue(at: index) == hash {
                let id = Int32(bitPattern: Self.readUInt32(
                    data,
                    at: hashRecordsOffset + index * Self.hashRecordSize + 8
                ))
                if tokenBytes(for: id, equal: bytes) {
                    return id
                }
                index += 1
            }
            return nil
        }

        func token(for id: Int32) -> String? {
            guard id >= 0, Int(id) < vocabularyCount else {
                return nil
            }
            let recordOffset = tokenRecordsOffset + Int(id) * Self.tokenRecordSize
            let offset = Int(Self.readUInt32(data, at: recordOffset))
            let length = Int(Self.readUInt32(data, at: recordOffset + 4))
            guard offset >= 0, length >= 0, offset + length <= data.count - tokenBlobOffset else {
                return nil
            }
            return String(decoding: data[(tokenBlobOffset + offset)..<(tokenBlobOffset + offset + length)], as: UTF8.self)
        }

        func merge(for key: UInt64) -> MergeValue? {
            var lower = 0
            var upper = mergeCount
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let recordOffset = mergeRecordsOffset + middle * Self.mergeRecordSize
                let current = Self.readUInt64(data, at: recordOffset)
                if current < key {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            guard lower < mergeCount else {
                return nil
            }
            let recordOffset = mergeRecordsOffset + lower * Self.mergeRecordSize
            guard Self.readUInt64(data, at: recordOffset) == key else {
                return nil
            }
            return MergeValue(
                rank: Int(Self.readUInt32(data, at: recordOffset + 8)),
                resultID: Int32(bitPattern: Self.readUInt32(data, at: recordOffset + 12))
            )
        }

        private func hashValue(at index: Int) -> UInt64 {
            Self.readUInt64(data, at: hashRecordsOffset + index * Self.hashRecordSize)
        }

        private func tokenBytes(for id: Int32, equal expected: [UInt8]) -> Bool {
            guard id >= 0, Int(id) < vocabularyCount else {
                return false
            }
            let recordOffset = tokenRecordsOffset + Int(id) * Self.tokenRecordSize
            let offset = Int(Self.readUInt32(data, at: recordOffset))
            let length = Int(Self.readUInt32(data, at: recordOffset + 4))
            guard
                length == expected.count,
                offset >= 0,
                offset + length <= data.count - tokenBlobOffset
            else {
                return false
            }
            for index in expected.indices where data[tokenBlobOffset + offset + index] != expected[index] {
                return false
            }
            return true
        }

        private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
            data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
            }
        }

        private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
            data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
            }
        }
    }

    private struct MergeCandidate {
        let firstID: Int32
        let secondID: Int32
        let rank: Int
        let resultID: Int32
    }

    public let configuration: Configuration
    private let storage: CompactStorage
    private let unknownID: Int32
    private let beginID: Int32
    private let endID: Int32
    private let paddingID: Int32
    private let byteFallback: Bool

    public init(tokenizerURL: URL, configuration: Configuration = Configuration()) throws {
        let data = try Data(contentsOf: tokenizerURL, options: [.mappedIfSafe])
        let storage = try CompactStorage(data: data)
        self.configuration = configuration
        self.storage = storage
        self.unknownID = storage.unknownID
        self.beginID = storage.beginID
        self.endID = storage.endID
        self.paddingID = storage.paddingID
        self.byteFallback = storage.byteFallback
    }

    public func tokenizeText(_ text: String) -> TokenizedText {
        let bodyBudget = max(configuration.maxSequenceLength - 2, 0)
        var ids: [Int32] = [beginID]
        ids.reserveCapacity(configuration.maxSequenceLength)

        outer: for token in preTokenize(text) {
            for id in bpeTokenIDs(for: token) {
                guard ids.count <= bodyBudget else {
                    break outer
                }
                ids.append(id)
            }
        }
        ids.append(endID)

        var mask = [Int32](repeating: 1, count: ids.count)
        if ids.count < configuration.maxSequenceLength {
            let padding = configuration.maxSequenceLength - ids.count
            ids.append(contentsOf: [Int32](repeating: paddingID, count: padding))
            mask.append(contentsOf: [Int32](repeating: 0, count: padding))
        }
        return TokenizedText(inputIDs: ids, attentionMask: mask)
    }

    public func tokens(_ text: String) -> [String] {
        preTokenize(text)
            .flatMap { bpeTokenIDs(for: $0) }
            .compactMap(token(for:))
    }

    private func preTokenize(_ text: String) -> [String] {
        let metaspace = Character("▁")
        let normalized = text.replacingOccurrences(of: " ", with: String(metaspace))
        let prepared = normalized.first == metaspace ? normalized : String(metaspace) + normalized
        var tokens: [String] = []
        var current = ""
        for character in prepared {
            if character == metaspace {
                if !current.isEmpty {
                    tokens.append(current)
                }
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func bpeTokenIDs(for token: String) -> [Int32] {
        var pieces = initialIDs(for: token)
        guard pieces.count > 1 else {
            return pieces
        }

        while let merge = bestMerge(in: pieces) {
            var merged: [Int32] = []
            merged.reserveCapacity(pieces.count)
            var index = 0
            while index < pieces.count {
                if
                    index < pieces.count - 1,
                    pieces[index] == merge.firstID,
                    pieces[index + 1] == merge.secondID
                {
                    merged.append(merge.resultID)
                    index += 2
                } else {
                    merged.append(pieces[index])
                    index += 1
                }
            }
            if merged == pieces {
                break
            }
            pieces = merged
        }
        return pieces
    }

    private func initialIDs(for token: String) -> [Int32] {
        token.flatMap { character -> [Int32] in
            let piece = String(character)
            if let id = tokenID(for: piece) {
                return [id]
            }
            guard byteFallback else {
                return [unknownID]
            }
            let ids = String(character).utf8.compactMap { byte in
                tokenID(for: String(format: "<0x%02X>", byte))
            }
            return ids.count == String(character).utf8.count ? ids : [unknownID]
        }
    }

    private func bestMerge(in pieces: [Int32]) -> MergeCandidate? {
        guard pieces.count > 1 else {
            return nil
        }
        var best: MergeCandidate?
        for index in 0..<(pieces.count - 1) {
            let firstID = pieces[index]
            let secondID = pieces[index + 1]
            guard let value = mergeValue(for: Self.pairKey(firstID, secondID)) else {
                continue
            }
            if best.map({ value.rank < $0.rank }) ?? true {
                best = MergeCandidate(
                    firstID: firstID,
                    secondID: secondID,
                    rank: value.rank,
                    resultID: value.resultID
                )
            }
        }
        return best
    }

    private func tokenID(for token: String) -> Int32? {
        storage.tokenID(for: token)
    }

    private func token(for id: Int32) -> String? {
        storage.token(for: id)
    }

    private func mergeValue(for key: UInt64) -> MergeValue? {
        storage.merge(for: key)
    }

    private static func pairKey(_ firstID: Int32, _ secondID: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: firstID)) << 32 | UInt64(UInt32(bitPattern: secondID))
    }

    private static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
