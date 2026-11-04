import Foundation

/// The slice of media a clip is transcribed from: the clip's own range plus a little on each side.
///
/// A clip cut out of a longer take — a blade edit, a jump cut — usually starts or ends mid-sentence,
/// sometimes mid-word. Transcribed on its own, the engine hears half a word with no context and
/// drops it or guesses something else. Giving it the neighbouring audio lets it hear the word
/// whole; the words that fall outside the clip are then thrown away, so nothing the timeline does
/// not play ever becomes a caption.
public struct TranscriptionWindow: Sendable, Equatable {
    /// Seconds of context on each side. Long enough to hold a word or two of Korean, short enough
    /// that the extra transcription time stays small next to the clip itself.
    public static let padding: TimeInterval = 1.5

    /// Seconds of context actually available before the clip — less than `padding` when the clip
    /// starts near the head of its media file.
    public var lead: TimeInterval
    /// Seconds of context asked for after the clip. The extractor stops at the end of the media,
    /// so near the tail of a file it simply gets less.
    public var trail: TimeInterval
    public var clipDuration: TimeInterval
    /// Where the clip starts inside the media file, in seconds.
    public var clipMediaStart: TimeInterval

    public init(clipMediaStart: TimeInterval, clipDuration: TimeInterval, padding: TimeInterval = Self.padding) {
        self.clipMediaStart = clipMediaStart
        self.clipDuration = clipDuration
        self.lead = max(0, min(padding, clipMediaStart))
        self.trail = max(0, padding)
    }

    /// Where to start extracting, in seconds into the media file.
    public var mediaStart: TimeInterval { clipMediaStart - lead }
    /// How much to extract.
    public var duration: TimeInterval { lead + clipDuration + trail }

    /// The engine's words, which are timed from the start of the extracted audio, as words timed
    /// from the start of the clip — keeping only the ones the clip actually plays.
    ///
    /// A word straddling a cut belongs to the side that holds most of it, judged by its midpoint.
    /// Two adjacent pieces of one take therefore never both caption the same word, and the
    /// boundary word is clamped to the clip so a caption never starts before it or runs past it.
    public func clipWords(_ words: [TranscriptWord]) -> [TranscriptWord] {
        words.compactMap { word in
            let start = word.start - lead
            let end = word.end - lead
            let middle = (start + end) / 2
            guard middle >= 0, middle < clipDuration else { return nil }
            return TranscriptWord(text: word.text,
                                  start: max(0, start),
                                  end: min(clipDuration, max(start, end)))
        }
    }
}
