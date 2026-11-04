import Foundation
import Testing
@testable import FCPCaptionCore

/// The context padding around a clip cut out of a longer take, and the mapping of the engine's
/// words back into the clip. Pure arithmetic, so every edge is pinned exactly.
struct TranscriptionWindowTests {
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end)
    }

    @Test func aClipInTheMiddleOfItsMediaGetsContextOnBothSides() {
        let window = TranscriptionWindow(clipMediaStart: 10, clipDuration: 4, padding: 1.5)
        #expect(window.lead == 1.5)
        #expect(window.mediaStart == 8.5)
        #expect(window.duration == 7)
    }

    @Test func aClipAtTheHeadOfItsMediaGetsNoLead() {
        let window = TranscriptionWindow(clipMediaStart: 0, clipDuration: 4, padding: 1.5)
        #expect(window.lead == 0)
        #expect(window.mediaStart == 0)
        #expect(window.duration == 5.5)
    }

    @Test func aClipNearTheHeadGetsOnlyTheLeadThatExists() {
        let window = TranscriptionWindow(clipMediaStart: 0.5, clipDuration: 4, padding: 1.5)
        #expect(window.lead == 0.5)
        #expect(window.mediaStart == 0)
    }

    @Test func wordsAreRetimedFromTheAudioToTheClip() {
        let window = TranscriptionWindow(clipMediaStart: 10, clipDuration: 4, padding: 1.5)
        let words = window.clipWords([word("오늘은", 2.0, 2.5), word("날씨가", 2.75, 3.25)])
        #expect(words == [word("오늘은", 0.5, 1.0), word("날씨가", 1.25, 1.75)])
    }

    @Test func wordsHeardOnlyInThePaddingAreDropped() {
        let window = TranscriptionWindow(clipMediaStart: 10, clipDuration: 4, padding: 1.5)
        let words = window.clipWords([
            word("앞", 0.2, 0.8),          // before the clip
            word("안녕하세요.", 1.6, 2.4),
            word("뒤", 5.8, 6.4),          // after it
        ])
        #expect(words.map(\.text) == ["안녕하세요."])
    }

    // The point of the padding: a word the cut slices through is heard whole, and kept by the
    // side holding most of it — clamped so its caption starts no earlier than the clip does.
    @Test func aWordCutAtTheHeadIsKeptWhenMostOfItIsInTheClip() {
        let window = TranscriptionWindow(clipMediaStart: 10, clipDuration: 4, padding: 1.5)
        let words = window.clipWords([word("그래서", 1.25, 2.25)])   // clip time -0.25...0.75
        #expect(words == [word("그래서", 0, 0.75)])
    }

    @Test func aWordCutAtTheHeadIsDroppedWhenMostOfItIsBefore() {
        let window = TranscriptionWindow(clipMediaStart: 10, clipDuration: 4, padding: 1.5)
        #expect(window.clipWords([word("그래서", 0.75, 1.75)]).isEmpty)   // clip time -0.75...0.25
    }

    @Test func aWordCutAtTheTailIsClampedToTheClipsEnd() {
        let window = TranscriptionWindow(clipMediaStart: 10, clipDuration: 4, padding: 1.5)
        let words = window.clipWords([word("좋네요.", 5.0, 5.75)])   // clip time 3.5...4.25
        #expect(words == [word("좋네요.", 3.5, 4)])
    }

    @Test func aWordCutAtTheTailIsDroppedWhenMostOfItIsAfter() {
        let window = TranscriptionWindow(clipMediaStart: 10, clipDuration: 4, padding: 1.5)
        #expect(window.clipWords([word("좋네요.", 5.25, 6.25)]).isEmpty)  // clip time 3.75...4.75
    }

    // Two pieces bladed from one continuous take: each hears the other's edge as context, and a
    // word on the cut must end up in exactly one of them — never captioned twice, never lost.
    @Test func adjacentPiecesOfOneTakeShareABoundaryWordExactlyOnce() {
        let first = TranscriptionWindow(clipMediaStart: 10, clipDuration: 4, padding: 1.5)
        let second = TranscriptionWindow(clipMediaStart: 14, clipDuration: 4, padding: 1.5)
        // "날씨가" sits at 13.75...14.5 in the media, across the cut at 14.
        let inFirst = first.clipWords([word("날씨가", 13.75 - first.mediaStart, 14.5 - first.mediaStart)])
        let inSecond = second.clipWords([word("날씨가", 13.75 - second.mediaStart, 14.5 - second.mediaStart)])
        #expect(inFirst.count + inSecond.count == 1)
        #expect(inSecond == [word("날씨가", 0, 0.5)])
    }

    @Test func noPaddingLeavesTimesAsTheEngineGaveThem() {
        let window = TranscriptionWindow(clipMediaStart: 10, clipDuration: 4, padding: 0)
        let words = [word("안녕하세요.", 0.2, 1.2), word("좋네요.", 2.8, 3.6)]
        #expect(window.clipWords(words) == words)
    }
}
