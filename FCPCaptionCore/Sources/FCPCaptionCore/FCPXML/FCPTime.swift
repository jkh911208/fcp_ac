import Foundation

/// A time as FCPXML writes it: an exact rational number of seconds, e.g. `1001/60000s`, `0s`.
///
/// Kept as the fraction it was read (or built) as, rather than reduced, because Final Cut Pro
/// writes unreduced values with the frame denominator (`180180/60000s`, not `3003/1000s`) and
/// round-tripping its documents should not rewrite them. Equality and ordering compare the
/// *value*, so `180180/60000s == 3003/1000s`.
public struct FCPTime: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let numerator: Int
    /// Always > 0.
    public let denominator: Int

    public init(_ numerator: Int, _ denominator: Int = 1) {
        precondition(denominator != 0, "FCPXML time with a zero denominator")
        if denominator < 0 {
            self.numerator = -numerator
            self.denominator = -denominator
        } else {
            self.numerator = numerator
            self.denominator = denominator
        }
    }

    public static let zero = FCPTime(0)

    /// An exact rational close to `seconds`, on a fine grid rather than the frame grid.
    ///
    /// Used to carry a transcription time into rational arithmetic *before* it is snapped to
    /// frames: aligning first and adding afterwards rounds twice, and two roundings against a
    /// clip start that is itself off-grid can drift a caption by a whole frame.
    public init(seconds: TimeInterval, precision: Int = 1_000_000) {
        self.init(Int((seconds * Double(precision)).rounded()), precision)
    }

    public var seconds: TimeInterval { Double(numerator) / Double(denominator) }

    /// `"0s"`, `"1001/60000s"` — exactly the form FCPXML expects.
    public var description: String {
        // Zero is written "0s" whatever denominator it carries, which is how FCP writes it.
        if numerator == 0 { return "0s" }
        return denominator == 1 ? "\(numerator)s" : "\(numerator)/\(denominator)s"
    }

    // MARK: - Parsing

    /// Parses an FCPXML time attribute. Accepts `"0s"`, `"14710/600s"`, and a bare number.
    public static func parse(_ raw: String) throws -> FCPTime {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.hasSuffix("s") ? String(text.dropLast()) : text
        guard !body.isEmpty else { throw FCPXMLError.malformedTime(raw) }

        if let slash = body.firstIndex(of: "/") {
            guard let numerator = Int(body[body.startIndex..<slash]),
                  let denominator = Int(body[body.index(after: slash)...]),
                  denominator != 0
            else { throw FCPXMLError.malformedTime(raw) }
            return FCPTime(numerator, denominator)
        }
        if let value = Int(body) { return FCPTime(value) }
        // Final Cut Pro always writes a rational, but other tools that produce FCPXML sometimes
        // write a decimal. Reading one costs nothing and widens what we can open; we still only
        // ever write rationals.
        if let value = Double(body), value.isFinite { return FCPTime(seconds: value) }
        throw FCPXMLError.malformedTime(raw)
    }

    // MARK: - Arithmetic

    /// Both sides over their least common denominator.
    ///
    /// Multiplying the denominators instead is the obvious version and it overflows: FCP writes a
    /// caption's internal start as ~1 hour over a 60000 denominator (`215999784/60000s`), and two
    /// chained operations on values that size run past `Int.max`. The LCM also keeps the
    /// denominator FCP uses, so `end - start` still prints as `180180/60000s`.
    private static func overCommonDenominator(_ lhs: FCPTime, _ rhs: FCPTime) -> (Int, Int, Int) {
        let divisor = greatestCommonDivisor(lhs.denominator, rhs.denominator)
        let common = lhs.denominator / divisor * rhs.denominator
        return (lhs.numerator * (common / lhs.denominator),
                rhs.numerator * (common / rhs.denominator),
                common)
    }

    public static func + (lhs: FCPTime, rhs: FCPTime) -> FCPTime {
        let (left, right, common) = overCommonDenominator(lhs, rhs)
        return FCPTime(left + right, common)
    }

    public static func - (lhs: FCPTime, rhs: FCPTime) -> FCPTime {
        let (left, right, common) = overCommonDenominator(lhs, rhs)
        return FCPTime(left - right, common)
    }

    public static func < (lhs: FCPTime, rhs: FCPTime) -> Bool {
        let (left, right, _) = overCommonDenominator(lhs, rhs)
        return left < right
    }

    public static func == (lhs: FCPTime, rhs: FCPTime) -> Bool {
        let (left, right, _) = overCommonDenominator(lhs, rhs)
        return left == right
    }

    public func hash(into hasher: inout Hasher) {
        let divisor = Self.greatestCommonDivisor(abs(numerator), denominator)
        hasher.combine(divisor == 0 ? 0 : numerator / divisor)
        hasher.combine(divisor == 0 ? 1 : denominator / divisor)
    }

    public func reduced() -> FCPTime {
        let divisor = Self.greatestCommonDivisor(abs(numerator), denominator)
        guard divisor > 1 else { return self }
        return FCPTime(numerator / divisor, denominator / divisor)
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    // MARK: - Frame alignment

    /// The rounding policy for putting a wall-clock time onto the timeline grid.
    ///
    /// Transcription gives us arbitrary seconds; FCP only accepts whole frames of the *sequence's*
    /// format. Which way we round is a decision, not a detail, so it is named and tested:
    /// a caption's start rounds **down** and its end rounds **up**, so frame quantization can
    /// only ever show a caption slightly early and slightly long — never clip a word's first or
    /// last frame. `nearest` exists for measurements where neither edge is privileged.
    public enum FrameRounding: Sendable {
        case down
        case up
        case nearest
    }

    /// Snaps to a whole multiple of `frameDuration`, keeping the frame denominator so the result
    /// prints the way Final Cut Pro prints it (`180180/60000s`).
    public func aligned(to frameDuration: FCPTime, rounding: FrameRounding = .nearest) -> FCPTime {
        guard frameDuration.numerator != 0 else { return self }

        // frames = self / frameDuration, exactly, as a fraction
        let frameNumerator = numerator * frameDuration.denominator
        let frameDenominator = denominator * frameDuration.numerator
        let exact = Double(frameNumerator) / Double(frameDenominator)
        let frames: Int
        switch rounding {
        case .down: frames = Int(exact.rounded(.down))
        case .up: frames = Int(exact.rounded(.up))
        case .nearest: frames = Int(exact.rounded(.toNearestOrAwayFromZero))
        }
        return FCPTime(frames * frameDuration.numerator, frameDuration.denominator)
    }

    /// How many whole frames this time is, at the given frame duration.
    public func frameCount(at frameDuration: FCPTime) -> Int {
        guard frameDuration.numerator != 0 else { return 0 }
        let exact = Double(numerator * frameDuration.denominator) / Double(denominator * frameDuration.numerator)
        return Int(exact.rounded(.toNearestOrAwayFromZero))
    }

    /// Seconds, snapped to the frame grid. The entry point from transcription times.
    public static func seconds(
        _ value: TimeInterval,
        alignedTo frameDuration: FCPTime,
        rounding: FrameRounding = .nearest
    ) -> FCPTime {
        guard frameDuration.numerator != 0 else { return FCPTime(Int(value.rounded()), 1) }
        let exactFrames = value * Double(frameDuration.denominator) / Double(frameDuration.numerator)
        let frames: Int
        switch rounding {
        case .down: frames = Int(exactFrames.rounded(.down))
        case .up: frames = Int(exactFrames.rounded(.up))
        case .nearest: frames = Int(exactFrames.rounded(.toNearestOrAwayFromZero))
        }
        return FCPTime(frames * frameDuration.numerator, frameDuration.denominator)
    }
}
