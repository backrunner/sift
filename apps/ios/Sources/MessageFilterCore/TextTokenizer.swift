import Foundation

public struct TokenizedText: Hashable, Sendable {
    public let inputIDs: [Int32]
    public let attentionMask: [Int32]

    public init(inputIDs: [Int32], attentionMask: [Int32]) {
        self.inputIDs = inputIDs
        self.attentionMask = attentionMask
    }
}

public protocol TextTokenizing: Sendable {
    func tokenizeText(_ text: String) -> TokenizedText
}

extension WordPieceTokenizer: TextTokenizing {
    public func tokenizeText(_ text: String) -> TokenizedText {
        let encoded: EncodedText = encode(text)
        return TokenizedText(inputIDs: encoded.inputIDs, attentionMask: encoded.attentionMask)
    }
}
