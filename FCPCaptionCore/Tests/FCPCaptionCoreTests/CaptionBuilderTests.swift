import Foundation
import Testing
@testable import FCPCaptionCore

/// §8 rules, one case per rule. Timings are the kind of thing Whisper actually returns for
/// Korean speech: ~0.1s between 어절, a beat between sentences.
struct CaptionBuilderTests {
    let builder = CaptionBuilder()

    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end)
    }

    // 1. Silence >= 0.6s always breaks, even mid-sentence with room to spare.
    @Test func silenceGapAlwaysBreaks() {
        let captions = builder.build(from: [
            word("안녕하세요", 0.0, 0.8),
            word("오늘은", 1.6, 2.2),
        ])
        #expect(captions.count == 2)
        #expect(captions[0].text == "안녕하세요")
        #expect(captions[1].text == "오늘은")
    }

    // ...and a gap just under the threshold does not.
    @Test func gapBelowThresholdDoesNotBreak() {
        let captions = builder.build(from: [
            word("안녕하세요", 0.0, 0.8),
            word("오늘은", 1.3, 1.9),
        ])
        #expect(captions.count == 1)
        #expect(captions[0].text == "안녕하세요 오늘은")
    }

    // 2. Sentence-ending punctuation breaks after the word that carries it.
    @Test func sentencePunctuationBreaks() {
        let captions = builder.build(from: [
            word("안녕하세요.", 0.0, 1.0),
            word("반갑습니다", 1.1, 2.3),
        ])
        #expect(captions.count == 2)
        #expect(captions[0].text == "안녕하세요.")
        #expect(captions[1].text == "반갑습니다")
    }

    @Test func sentencePunctuationInsideQuotesStillBreaks() {
        let captions = builder.build(from: [
            word("\"좋아요!\"", 0.0, 1.0),
            word("그럼", 1.1, 1.6),
        ])
        #expect(captions.count == 2)
    }

    // 3. A comma breaks only once the caption already holds a full line.
    @Test func commaDoesNotBreakShortCaption() {
        let captions = builder.build(from: [
            word("네,", 0.0, 0.5),
            word("그래서", 0.6, 1.2),
            word("지금", 1.3, 1.8),
        ])
        #expect(captions.count == 1)
        #expect(captions[0].text == "네, 그래서 지금")
    }

    @Test func commaBreaksOnceLineIsFull() {
        let captions = builder.build(from: [
            word("저는", 0.0, 0.4),
            word("오늘", 0.5, 0.9),
            word("아침에", 1.0, 1.5),
            word("일찍", 1.6, 2.0),
            word("일어나서,", 2.1, 2.8),   // 18 characters so far
            word("운동을", 2.9, 3.4),
            word("했습니다.", 3.5, 4.2),
        ])
        #expect(captions.count == 2)
        #expect(captions[0].text == "저는 오늘 아침에 일찍 일어나서,")
        #expect(captions[1].text == "운동을 했습니다.")
    }

    // 4. The character budget (2 lines x 18) cuts at the last word boundary that fits.
    @Test func characterBudgetBreaks() {
        let texts = ["오늘은", "날씨가", "정말", "좋아서", "가족들과", "함께", "공원에", "산책을", "나갔는데요"]
        var words: [TranscriptWord] = []
        for (index, text) in texts.enumerated() {
            words.append(word(text, Double(index) * 0.6, Double(index) * 0.6 + 0.5))
        }
        let captions = builder.build(from: words)
        #expect(captions.count > 1)
        for caption in captions {
            #expect(caption.text.replacingOccurrences(of: "\n", with: " ").count <= 36)
            #expect(caption.lines.count <= 2)
            for line in caption.lines {
                #expect(line.count <= 18)
            }
        }
        // nothing lost, nothing reordered
        #expect(captions.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) } == texts)
    }

    // 5 & 6. Layout: one line while it fits, two balanced lines when it doesn't.
    @Test func shortCaptionStaysOnOneLine() {
        #expect(builder.layout(["안녕하세요", "여러분"]) == ["안녕하세요 여러분"])
    }

    @Test func longCaptionSplitsIntoBalancedLines() {
        let lines = builder.layout(["오늘은", "날씨가", "정말", "좋아서", "공원에", "나왔어요"])
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.count <= 18 })
        #expect(abs(lines[0].count - lines[1].count) <= 4)
    }

    // 7. An 어절 is never split, even when it alone is longer than a line.
    @Test func overlongWordOverflowsRatherThanSplitting() {
        let token = String(repeating: "가", count: 25)
        let lines = builder.layout([token])
        #expect(lines == [token])
    }

    // 8. A caption is cut before it grows past maxDuration.
    @Test func maximumDurationBreaks() {
        var words: [TranscriptWord] = []
        for index in 0..<9 {
            words.append(word("음", Double(index) * 0.8, Double(index) * 0.8 + 0.7))
        }
        let captions = builder.build(from: words)
        #expect(captions.count > 1)
        for caption in captions {
            #expect(caption.duration <= 6.0 + 0.0001)
        }
    }

    // 9. A short caption is held to minDuration, but never into the next one.
    @Test func shortCaptionIsExtendedToMinimumDuration() {
        let captions = builder.build(from: [word("네", 0.0, 0.4)])
        #expect(captions.count == 1)
        #expect(abs(captions[0].end - 1.0) < 0.0001)
    }

    @Test func minimumDurationNeverEatsIntoTheNextCaption() {
        let captions = builder.build(from: [
            word("네", 0.0, 0.3),
            word("좋아요", 0.95, 1.6),
        ])
        #expect(captions.count == 2)
        #expect(abs(captions[0].end - 0.95) < 0.0001)   // stops exactly where the next begins
        #expect(captions[0].end <= captions[1].start)
    }

    // 10. Overlapping word timings (chunk seams) pull the earlier caption back.
    @Test func overlappingCaptionsAreTrimmed() {
        let captions = builder.build(from: [
            word("안녕하세요.", 0.0, 2.0),
            word("반갑습니다", 1.9, 2.5),
        ])
        #expect(captions.count == 2)
        #expect(abs(captions[0].end - 1.9) < 0.0001)
        #expect(captions[0].end <= captions[1].start)
    }

    // 11. Engines that return segments only still caption.
    @Test func segmentOnlyResultsAreCaptioned() {
        let captions = builder.build(from: [
            TranscriptSegment(text: "안녕하세요 반갑습니다", start: 0, end: 4)
        ])
        #expect(captions.count == 1)
        #expect(captions[0].text == "안녕하세요 반갑습니다")
        #expect(abs(captions[0].start - 0) < 0.0001)
        #expect(abs(captions[0].end - 4) < 0.0001)
    }

    @Test func segmentWordsArePreferredOverApproximation() {
        let segment = TranscriptSegment(
            text: "안녕하세요 반갑습니다",
            start: 0,
            end: 4,
            words: [word("안녕하세요", 0.0, 1.0), word("반갑습니다", 3.0, 3.5)]
        )
        #expect(segment.approximateWords() == segment.words)
        let captions = builder.build(from: [segment])
        #expect(captions.count == 2)   // the 2.0s hole between them is a hard break
    }

    @Test func approximatedWordsSplitTheSegmentByCharacterCount() {
        let words = TranscriptSegment(text: "가 나나나", start: 0, end: 6).approximateWords()
        #expect(words.count == 2)
        #expect(abs(words[0].start - 0) < 0.0001)
        #expect(abs(words[0].end - 2) < 0.0001)      // weight 2 of 6
        #expect(abs(words[1].end - 6) < 0.0001)
    }

    // 12–13. Degenerate input.
    @Test func emptyInputProducesNoCaptions() {
        #expect(builder.build(from: [TranscriptWord]()).isEmpty)
        #expect(builder.build(from: [TranscriptSegment(text: "   ", start: 0, end: 1)]).isEmpty)
    }

    @Test func wordsAreSortedAndTrimmed() {
        let captions = builder.build(from: [
            word(" 반갑습니다", 1.1, 2.3),
            word("안녕하세요.", 0.0, 1.0),
            word("  ", 2.4, 2.6),
        ])
        #expect(captions.count == 2)
        #expect(captions[0].text == "안녕하세요.")
        #expect(captions[1].text == "반갑습니다")
    }

    // Options are honoured, not just the defaults.
    @Test func customOptionsChangeTheSplit() {
        let narrow = CaptionBuilder(options: CaptionSplitOptions(maxCharactersPerLine: 6, maxLines: 1))
        let captions = narrow.build(from: [
            word("안녕하세요", 0.0, 0.5),
            word("여러분", 0.6, 1.1),
        ])
        #expect(captions.count == 2)
        #expect(captions.allSatisfy { $0.lines.count == 1 })
    }
}
