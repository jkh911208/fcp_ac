import Foundation

/// A single word (or, for languages without spaces, a token) with its timing in the source audio.
/// Times are seconds from the start of the *clip*, not of the audio chunk it was decoded from —
/// chunked extraction adds the chunk offset before the words reach this type.
public struct TranscriptWord: Sendable, Equatable, Codable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A contiguous stretch of speech as an engine reported it.
///
/// `words` is empty when the engine returned segment-level timing only (an OpenAI-compatible
/// endpoint asked without `timestamp_granularities`, or a local model run with word timestamps
/// off). `approximateWords()` turns such a segment into word timings good enough to caption.
public struct TranscriptSegment: Sendable, Equatable, Codable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var words: [TranscriptWord]

    public init(text: String, start: TimeInterval, end: TimeInterval, words: [TranscriptWord] = []) {
        self.text = text
        self.start = start
        self.end = end
        self.words = words
    }
}

extension TranscriptSegment {
    /// Word timings derived by splitting the segment's duration across its tokens in proportion to
    /// their character count. Used only when the engine gave us no word timestamps.
    ///
    /// Spacing counts toward a token's weight, so a segment reads out at a roughly even rate. The
    /// result is never better than the segment's own boundaries — that is the point of the fallback.
    public func approximateWords() -> [TranscriptWord] {
        if !words.isEmpty { return words }

        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let weights = tokens.map { Double($0.count) + 1 }  // +1 for the space that follows
        let total = weights.reduce(0, +)
        let duration = max(0, end - start)
        guard total > 0, duration > 0 else {
            return tokens.map { TranscriptWord(text: $0, start: start, end: end) }
        }

        var cursor = start
        return zip(tokens, weights).map { token, weight in
            let wordStart = cursor
            cursor += duration * (weight / total)
            return TranscriptWord(text: token, start: wordStart, end: cursor)
        }
    }
}
