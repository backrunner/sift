import Foundation

/// BERT-style WordPiece tokenizer.
///
/// Mirrors Hugging Face `BertTokenizer` behavior: control-character cleanup,
/// whitespace splitting, CJK characters isolated as single tokens, punctuation
/// splitting, optional lowercasing with accent stripping, then greedy
/// longest-match WordPiece with `##` continuations. This keeps the on-device
/// tokenization byte-compatible with corpora tokenized by
/// `tools/transformer-trainer` for WordPiece-vocabulary backbones.
public struct WordPieceTokenizer: Sendable {
    public struct Configuration: Hashable, Sendable {
        public var doLowerCase: Bool
        public var maxSequenceLength: Int
        public var maxWordCharacters: Int
        public var unknownToken: String
        public var classToken: String
        public var separatorToken: String
        public var paddingToken: String

        public init(
            doLowerCase: Bool = false,
            maxSequenceLength: Int = 96,
            maxWordCharacters: Int = 100,
            unknownToken: String = "[UNK]",
            classToken: String = "[CLS]",
            separatorToken: String = "[SEP]",
            paddingToken: String = "[PAD]"
        ) {
            self.doLowerCase = doLowerCase
            self.maxSequenceLength = maxSequenceLength
            self.maxWordCharacters = maxWordCharacters
            self.unknownToken = unknownToken
            self.classToken = classToken
            self.separatorToken = separatorToken
            self.paddingToken = paddingToken
        }
    }

    public struct EncodedText: Hashable, Sendable {
        public let inputIDs: [Int32]
        public let attentionMask: [Int32]
    }

    /// Offset-aware encoding for token-classification models: every sequence
    /// position maps back to a word range in the original string (nil for
    /// special/padding positions), so per-token predictions can be projected
    /// onto character ranges. Redaction granularity is the whole word — a
    /// deliberately coarse, safe choice.
    public struct EncodedTextWithOffsets: Sendable {
        public let inputIDs: [Int32]
        public let attentionMask: [Int32]
        public let wordIndices: [Int?]
        public let wordRanges: [Range<String.Index>]
    }

    public enum TokenizerError: Error, Hashable {
        case emptyVocabulary
        case missingSpecialToken(String)
    }

    public let configuration: Configuration
    private let vocabulary: [String: Int32]
    private let unknownID: Int32
    private let classID: Int32
    private let separatorID: Int32
    private let paddingID: Int32

    public init(vocabulary: [String: Int32], configuration: Configuration = Configuration()) throws {
        guard !vocabulary.isEmpty else {
            throw TokenizerError.emptyVocabulary
        }
        for token in [configuration.unknownToken, configuration.classToken, configuration.separatorToken, configuration.paddingToken]
        where vocabulary[token] == nil {
            throw TokenizerError.missingSpecialToken(token)
        }

        self.configuration = configuration
        self.vocabulary = vocabulary
        self.unknownID = vocabulary[configuration.unknownToken]!
        self.classID = vocabulary[configuration.classToken]!
        self.separatorID = vocabulary[configuration.separatorToken]!
        self.paddingID = vocabulary[configuration.paddingToken]!
    }

    /// Loads a `vocab.txt` (one token per line; the line index is the id).
    ///
    /// A trailing newline is ignored; any other blank line still consumes its
    /// id (without becoming a lookupable token) so ids never shift silently.
    public init(vocabularyFileURL: URL, configuration: Configuration = Configuration()) throws {
        let contents = try String(contentsOf: vocabularyFileURL, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }

        var vocabulary: [String: Int32] = [:]
        vocabulary.reserveCapacity(lines.count)
        for (index, token) in lines.enumerated() where !token.isEmpty {
            if vocabulary[token] == nil {
                vocabulary[token] = Int32(index)
            }
        }
        try self.init(vocabulary: vocabulary, configuration: configuration)
    }

    /// Full encoding: `[CLS] tokens… [SEP]`, truncated and padded to
    /// `maxSequenceLength`.
    public func encode(_ text: String) -> EncodedText {
        let pieces = tokenize(text)
        let bodyBudget = configuration.maxSequenceLength - 2
        var ids: [Int32] = [classID]
        ids.reserveCapacity(configuration.maxSequenceLength)
        for piece in pieces.prefix(max(bodyBudget, 0)) {
            ids.append(vocabulary[piece] ?? unknownID)
        }
        ids.append(separatorID)

        var mask = [Int32](repeating: 1, count: ids.count)
        if ids.count < configuration.maxSequenceLength {
            let padding = configuration.maxSequenceLength - ids.count
            ids.append(contentsOf: [Int32](repeating: paddingID, count: padding))
            mask.append(contentsOf: [Int32](repeating: 0, count: padding))
        }
        return EncodedText(inputIDs: ids, attentionMask: mask)
    }

    /// Basic + WordPiece tokenization, without special tokens.
    public func tokenize(_ text: String) -> [String] {
        basicTokens(from: text).flatMap { wordPieces(for: $0) }
    }

    /// Offset-aware encoding: `[CLS] pieces… [SEP]` with, for every position,
    /// the index of the source word it came from.
    public func encodeWithOffsets(_ text: String) -> EncodedTextWithOffsets {
        let words = wordsWithRanges(in: text)

        var ids: [Int32] = [classID]
        var wordIndices: [Int?] = [nil]
        var wordRanges: [Range<String.Index>] = []
        let bodyBudget = max(configuration.maxSequenceLength - 2, 0)

        outer: for word in words {
            let wordIndex = wordRanges.count
            var appendedForWord = false
            for piece in wordPieces(for: word.lookup) {
                if ids.count - 1 >= bodyBudget {
                    if appendedForWord {
                        wordRanges.append(word.range)
                    }
                    break outer
                }
                ids.append(vocabulary[piece] ?? unknownID)
                wordIndices.append(wordIndex)
                appendedForWord = true
            }
            if appendedForWord {
                wordRanges.append(word.range)
            }
        }

        ids.append(separatorID)
        wordIndices.append(nil)

        var mask = [Int32](repeating: 1, count: ids.count)
        if ids.count < configuration.maxSequenceLength {
            let padding = configuration.maxSequenceLength - ids.count
            ids.append(contentsOf: [Int32](repeating: paddingID, count: padding))
            mask.append(contentsOf: [Int32](repeating: 0, count: padding))
            wordIndices.append(contentsOf: [Int?](repeating: nil, count: padding))
        }

        return EncodedTextWithOffsets(
            inputIDs: ids,
            attentionMask: mask,
            wordIndices: wordIndices,
            wordRanges: wordRanges
        )
    }

    // MARK: - Basic tokenizer

    private struct OffsetWord {
        /// Range in the original string covered by this word.
        let range: Range<String.Index>
        /// Normalized text used for vocabulary lookup (lowercased/folded when
        /// configured); may differ in length from the original slice.
        let lookup: String
    }

    /// Splits the original text into basic-tokenizer words while preserving
    /// their source ranges: whitespace/control separates, CJK characters and
    /// punctuation become single-character words.
    private func wordsWithRanges(in text: String) -> [OffsetWord] {
        var words: [OffsetWord] = []
        var currentStart: String.Index?
        var index = text.startIndex

        func flush(upTo end: String.Index) {
            guard let start = currentStart else { return }
            appendWord(text: text, range: start..<end, into: &words)
            currentStart = nil
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let scalar = character.unicodeScalars.first!

            if character.unicodeScalars.count == 1 && (scalar.value == 0 || scalar.value == 0xFFFD || isControl(scalar) || isWhitespace(scalar)) {
                flush(upTo: index)
            } else if character.unicodeScalars.count == 1 && isCJKCharacter(scalar) {
                flush(upTo: index)
                words.append(OffsetWord(range: index..<next, lookup: String(character)))
            } else if isPunctuation(character) {
                flush(upTo: index)
                words.append(OffsetWord(range: index..<next, lookup: normalizeForLookup(String(character))))
            } else if currentStart == nil {
                currentStart = index
            }
            index = next
        }
        flush(upTo: text.endIndex)
        return words
    }

    private func appendWord(text: String, range: Range<String.Index>, into words: inout [OffsetWord]) {
        words.append(OffsetWord(range: range, lookup: normalizeForLookup(String(text[range]))))
    }

    private func normalizeForLookup(_ word: String) -> String {
        guard configuration.doLowerCase else {
            return word
        }
        return word.lowercased().folding(options: .diacriticInsensitive, locale: nil)
    }

    private func basicTokens(from text: String) -> [String] {
        var spaced = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD || isControl(scalar) {
                continue
            }
            if isCJKCharacter(scalar) {
                spaced.append(" ")
                spaced.append(scalar)
                spaced.append(" ")
            } else if isWhitespace(scalar) {
                spaced.append(" ")
            } else {
                spaced.append(scalar)
            }
        }

        var tokens: [String] = []
        for word in String(spaced).split(separator: " ", omittingEmptySubsequences: true) {
            var normalized = String(word)
            if configuration.doLowerCase {
                normalized = normalized.lowercased()
                normalized = normalized.folding(options: .diacriticInsensitive, locale: nil)
            }
            tokens.append(contentsOf: splitOnPunctuation(normalized))
        }
        return tokens
    }

    private func splitOnPunctuation(_ word: String) -> [String] {
        var output: [String] = []
        var current = ""
        for character in word {
            if isPunctuation(character) {
                if !current.isEmpty {
                    output.append(current)
                    current = ""
                }
                output.append(String(character))
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            output.append(current)
        }
        return output
    }

    // MARK: - WordPiece

    private func wordPieces(for word: String) -> [String] {
        let characters = Array(word)
        guard characters.count <= configuration.maxWordCharacters else {
            return [configuration.unknownToken]
        }

        var pieces: [String] = []
        var start = 0
        while start < characters.count {
            var end = characters.count
            var match: String?
            while start < end {
                var candidate = String(characters[start..<end])
                if start > 0 {
                    candidate = "##" + candidate
                }
                if vocabulary[candidate] != nil {
                    match = candidate
                    break
                }
                end -= 1
            }
            guard let match else {
                return [configuration.unknownToken]
            }
            pieces.append(match)
            start = end
        }
        return pieces
    }

    // MARK: - Character classes (mirrors BERT reference implementation)

    private func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case " ", "\t", "\n", "\r":
            return true
        default:
            return scalar.properties.generalCategory == .spaceSeparator
        }
    }

    private func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\t", "\n", "\r":
            return false
        default:
            switch scalar.properties.generalCategory {
            case .control, .format:
                return true
            default:
                return false
            }
        }
    }

    private func isPunctuation(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return false
        }
        let value = scalar.value
        if (33...47).contains(value) || (58...64).contains(value) || (91...96).contains(value) || (123...126).contains(value) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private func isCJKCharacter(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x20000...0x2A6DF).contains(value)
            || (0x2A700...0x2B73F).contains(value)
            || (0x2B740...0x2B81F).contains(value)
            || (0x2B820...0x2CEAF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x2F800...0x2FA1F).contains(value)
    }
}
