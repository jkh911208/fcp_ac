import Foundation

/// Turns word timings into caption units under the §8 Korean rules.
///
/// Break priority, highest first:
/// 1. silence between words >= `silenceGap` — always breaks;
/// 2. after sentence-ending punctuation (`.` `?` `!` `…`);
/// 3. after a comma, once the caption already holds a full line;
/// 4. on the character/duration budget, at the last word boundary that fits.
///
/// An 어절 (whitespace-delimited word) is never split, at any priority.
public struct CaptionBuilder: Sendable {
    public var options: CaptionSplitOptions

    public init(options: CaptionSplitOptions = .default) {
        self.options = options
    }

    // MARK: - Building

    /// Captions from segments. Segments the engine gave no word timings for are approximated
    /// (see `TranscriptSegment.approximateWords()`), so a segment-only engine still captions.
    public func build(from segments: [TranscriptSegment]) -> [Caption] {
        build(from: segments.flatMap { $0.approximateWords() })
    }

    public func build(from words: [TranscriptWord]) -> [Caption] {
        let words = normalize(words)
        guard !words.isEmpty else { return [] }

        var captions = group(words).map { group in
            Caption(
                lines: layout(group.map(\.text)),
                start: group[0].start,
                end: group[group.count - 1].end
            )
        }
        applyMinimumDuration(&captions)
        removeOverlaps(&captions)
        return captions
    }

    // MARK: - Grouping

    private func normalize(_ words: [TranscriptWord]) -> [TranscriptWord] {
        words
            .map { TranscriptWord(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  start: $0.start,
                                  end: max($0.start, $0.end)) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.start < $1.start }
    }

    private func group(_ words: [TranscriptWord]) -> [[TranscriptWord]] {
        var groups: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []

        func flush() {
            if !current.isEmpty {
                groups.append(current)
                current = []
            }
        }

        for word in words {
            if let previous = current.last {
                let silence = word.start - previous.end
                let projectedDuration = word.end - current[0].start

                if silence >= options.silenceGap
                    || !fitsOnScreen(current.map(\.text) + [word.text])
                    || projectedDuration > options.maxDuration {
                    flush()
                }
            }

            current.append(word)

            if endsSentence(word.text) {
                flush()
            } else if endsClause(word.text), characterCount(current.map(\.text)) >= options.maxCharactersPerLine {
                // A comma only earns a break once the caption is already worth showing on its own;
                // otherwise short clauses each become their own one-second flash.
                flush()
            }
        }
        flush()
        return groups
    }

    private func characterCount(_ tokens: [String]) -> Int {
        tokens.joined(separator: " ").count
    }

    /// Whether these tokens can be shown at once: greedy first-fit wrapping — which is optimal for
    /// line count when tokens keep their order and are never split — must land within `maxLines`.
    ///
    /// Counting the total characters instead is not the same test and lets a caption through that
    /// cannot be laid out: nine 어절 totalling exactly 36 characters still needs three lines when no
    /// break falls near the middle, and the layout pass then has to overflow a line to fit it.
    private func fitsOnScreen(_ tokens: [String]) -> Bool {
        var lines = 1
        var width = -1  // -1 marks "line is empty"; the first token joins with no leading space
        for token in tokens {
            if width < 0 {
                width = token.count   // a token wider than the line stands alone and overflows
            } else if width + 1 + token.count <= options.maxCharactersPerLine {
                width += 1 + token.count
            } else {
                lines += 1
                if lines > options.maxLines { return false }
                width = token.count
            }
        }
        return true
    }

    private static let sentenceEnders: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]
    private static let clauseEnders: Set<Character> = [",", "，", "、"]
    private static let trailingWrappers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "」", "』", "》"]

    private func significantLastCharacter(_ text: String) -> Character? {
        var text = Substring(text)
        while let last = text.last, Self.trailingWrappers.contains(last) {
            text = text.dropLast()
        }
        return text.last
    }

    private func endsSentence(_ text: String) -> Bool {
        guard let last = significantLastCharacter(text) else { return false }
        return Self.sentenceEnders.contains(last)
    }

    private func endsClause(_ text: String) -> Bool {
        guard let last = significantLastCharacter(text) else { return false }
        return Self.clauseEnders.contains(last)
    }

    // MARK: - Line layout

    /// Lays tokens out over at most `maxLines` lines, never splitting a token.
    ///
    /// Picks the arrangement with the least squared slack, which both fills lines and balances
    /// them — a 30-character caption comes out 15/15, not 18/12. A token longer than a whole line
    /// overflows rather than being cut, and the overflow is heavily penalized so it never happens
    /// when any legal arrangement exists.
    func layout(_ tokens: [String]) -> [String] {
        let tokens = tokens.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        let counts = tokens.map(\.count)
        let limit = options.maxCharactersPerLine

        // width of tokens[i..<j] joined by single spaces
        func width(_ i: Int, _ j: Int) -> Int {
            guard j > i else { return 0 }
            return counts[i..<j].reduce(0, +) + (j - i - 1)
        }
        func lineCost(_ w: Int) -> Double {
            let slack = Double(limit - w)
            return w > limit ? 10_000 * Double(w - limit) + slack * slack : slack * slack
        }

        var memo: [Int: (cost: Double, breaks: [Int])] = [:]
        func best(from start: Int, linesLeft: Int) -> (cost: Double, breaks: [Int]) {
            if start == tokens.count { return (0, []) }
            if linesLeft == 1 { return (lineCost(width(start, tokens.count)), [tokens.count]) }
            let key = start * (options.maxLines + 1) + linesLeft
            if let cached = memo[key] { return cached }

            var bestResult = (cost: Double.infinity, breaks: [Int]())
            for end in (start + 1)...tokens.count {
                let rest = best(from: end, linesLeft: linesLeft - 1)
                let cost = lineCost(width(start, end)) + rest.cost
                if cost < bestResult.cost {
                    bestResult = (cost, [end] + rest.breaks)
                }
            }
            memo[key] = bestResult
            return bestResult
        }

        let breaks = best(from: 0, linesLeft: options.maxLines).breaks
        var lines: [String] = []
        var start = 0
        for end in breaks where end > start {
            lines.append(tokens[start..<end].joined(separator: " "))
            start = end
        }
        return lines
    }

    // MARK: - Timing

    private func applyMinimumDuration(_ captions: inout [Caption]) {
        for index in captions.indices where captions[index].duration < options.minDuration {
            let desired = captions[index].start + options.minDuration
            let ceiling = index + 1 < captions.count ? captions[index + 1].start : .greatestFiniteMagnitude
            captions[index].end = max(captions[index].end, min(desired, ceiling))
        }
    }

    /// Word timings from different chunks can overlap by a few milliseconds; FCP would reject
    /// overlapping captions in one lane, so the earlier caption gives way.
    private func removeOverlaps(_ captions: inout [Caption]) {
        guard captions.count > 1 else { return }
        for index in 0..<(captions.count - 1) where captions[index].end > captions[index + 1].start {
            captions[index].end = max(captions[index].start, captions[index + 1].start)
        }
    }
}
