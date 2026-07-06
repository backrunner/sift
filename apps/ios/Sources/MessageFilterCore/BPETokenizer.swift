import Foundation

/// Hugging Face BPE tokenizer subset used by mmBERT.
///
/// Supports the mmBERT tokenizer JSON shape: metaspace pre-tokenization,
/// template processing with BOS/EOS, BPE merge ranks, and byte fallback.
public struct BPETokenizer: TextTokenizing, Sendable {
    public struct Configuration: Hashable, Sendable {
        public var maxSequenceLength: Int

        public init(maxSequenceLength: Int = 96) {
            self.maxSequenceLength = maxSequenceLength
        }
    }

    public enum TokenizerError: Error, Hashable {
        case missingModel
        case unsupportedModel(String)
        case missingSpecialToken(String)
        case invalidMerge
    }

    private struct TokenizerDocument: Decodable {
        let model: Model
        let postProcessor: PostProcessor?

        enum CodingKeys: String, CodingKey {
            case model
            case postProcessor = "post_processor"
        }
    }

    private struct Model: Decodable {
        let type: String
        let vocab: [String: Int32]
        let merges: [Merge]
        let byteFallback: Bool?
        let unknownToken: String?

        enum CodingKeys: String, CodingKey {
            case type
            case vocab
            case merges
            case byteFallback = "byte_fallback"
            case unknownToken = "unk_token"
        }
    }

    private struct Merge: Decodable {
        let first: String
        let second: String

        init(from decoder: Decoder) throws {
            if var container = try? decoder.unkeyedContainer() {
                first = try container.decode(String.self)
                second = try container.decode(String.self)
                return
            }
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let separator = raw.firstIndex(of: " ") else {
                throw TokenizerError.invalidMerge
            }
            first = String(raw[..<separator])
            second = String(raw[raw.index(after: separator)...])
        }
    }

    private struct PostProcessor: Decodable {
        let specialTokens: [String: SpecialToken]?

        enum CodingKeys: String, CodingKey {
            case specialTokens = "special_tokens"
        }
    }

    private struct SpecialToken: Decodable {
        let ids: [Int32]
        let tokens: [String]
    }

    public let configuration: Configuration
    private let vocabulary: [String: Int32]
    private let mergeRanks: [PairKey: Int]
    private let unknownToken: String
    private let unknownID: Int32
    private let beginID: Int32
    private let endID: Int32
    private let paddingID: Int32
    private let byteFallback: Bool

    private struct PairKey: Hashable, Sendable {
        let first: String
        let second: String
    }

    public init(tokenizerJSONURL: URL, configuration: Configuration = Configuration()) throws {
        let data = try Data(contentsOf: tokenizerJSONURL)
        let document = try JSONDecoder().decode(TokenizerDocument.self, from: data)
        try self.init(document: document, configuration: configuration)
    }

    init(tokenizerJSONData: Data, configuration: Configuration = Configuration()) throws {
        let document = try JSONDecoder().decode(TokenizerDocument.self, from: tokenizerJSONData)
        try self.init(document: document, configuration: configuration)
    }

    private init(document: TokenizerDocument, configuration: Configuration) throws {
        guard document.model.type == "BPE" else {
            throw TokenizerError.unsupportedModel(document.model.type)
        }
        let vocabulary = document.model.vocab
        let unknownToken = document.model.unknownToken ?? "<unk>"
        let beginToken = document.postProcessor?.specialTokens?["<bos>"]?.tokens.first ?? "<bos>"
        let endToken = document.postProcessor?.specialTokens?["<eos>"]?.tokens.first ?? "<eos>"
        let paddingToken = "<pad>"
        guard let unknownID = vocabulary[unknownToken] else {
            throw TokenizerError.missingSpecialToken(unknownToken)
        }
        guard let beginID = vocabulary[beginToken] else {
            throw TokenizerError.missingSpecialToken(beginToken)
        }
        guard let endID = vocabulary[endToken] else {
            throw TokenizerError.missingSpecialToken(endToken)
        }
        guard let paddingID = vocabulary[paddingToken] else {
            throw TokenizerError.missingSpecialToken(paddingToken)
        }

        var ranks: [PairKey: Int] = [:]
        ranks.reserveCapacity(document.model.merges.count)
        for (rank, merge) in document.model.merges.enumerated() {
            ranks[PairKey(first: merge.first, second: merge.second)] = rank
        }

        self.configuration = configuration
        self.vocabulary = vocabulary
        self.mergeRanks = ranks
        self.unknownToken = unknownToken
        self.unknownID = unknownID
        self.beginID = beginID
        self.endID = endID
        self.paddingID = paddingID
        self.byteFallback = document.model.byteFallback ?? false
    }

    public func tokenizeText(_ text: String) -> TokenizedText {
        let bodyBudget = max(configuration.maxSequenceLength - 2, 0)
        var ids: [Int32] = [beginID]
        ids.reserveCapacity(configuration.maxSequenceLength)
        for token in preTokenize(text).flatMap({ bpeTokens(for: $0) }).prefix(bodyBudget) {
            ids.append(vocabulary[token] ?? unknownID)
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
        preTokenize(text).flatMap { bpeTokens(for: $0) }
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

    private func bpeTokens(for token: String) -> [String] {
        var pieces = initialPieces(for: token)
        guard pieces.count > 1 else {
            return pieces
        }

        while let merge = bestMerge(in: pieces) {
            var merged: [String] = []
            var index = 0
            while index < pieces.count {
                if
                    index < pieces.count - 1,
                    pieces[index] == merge.first,
                    pieces[index + 1] == merge.second
                {
                    merged.append(merge.first + merge.second)
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

    private func initialPieces(for token: String) -> [String] {
        token.map { character in
            let piece = String(character)
            if vocabulary[piece] != nil {
                return [piece]
            }
            guard byteFallback else {
                return [unknownToken]
            }
            let bytes = String(character).utf8.map { byte in
                String(format: "<0x%02X>", byte)
            }
            return bytes.allSatisfy { vocabulary[$0] != nil } ? bytes : [unknownToken]
        }
        .flatMap { $0 }
    }

    private func bestMerge(in pieces: [String]) -> PairKey? {
        guard pieces.count > 1 else {
            return nil
        }
        var bestPair: PairKey?
        var bestRank = Int.max
        for index in 0..<(pieces.count - 1) {
            let pair = PairKey(first: pieces[index], second: pieces[index + 1])
            guard let rank = mergeRanks[pair], rank < bestRank else {
                continue
            }
            bestRank = rank
            bestPair = pair
        }
        return bestPair
    }
}
