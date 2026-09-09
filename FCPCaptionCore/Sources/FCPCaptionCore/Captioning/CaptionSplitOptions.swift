import Foundation

/// The §8 Korean caption rules, all adjustable from Settings.
public struct CaptionSplitOptions: Sendable, Equatable, Codable {
    /// Maximum characters on one line, spaces included. Korean reads at roughly 18 per line
    /// in FCP's default caption size.
    public var maxCharactersPerLine: Int
    public var maxLines: Int
    /// A caption shorter than this is held on screen longer (never past the next caption's start).
    public var minDuration: TimeInterval
    /// A caption is cut before it grows past this.
    public var maxDuration: TimeInterval
    /// Silence between two words that always ends a caption, whatever the text says.
    public var silenceGap: TimeInterval

    public init(
        maxCharactersPerLine: Int = 18,
        maxLines: Int = 2,
        minDuration: TimeInterval = 1.0,
        maxDuration: TimeInterval = 6.0,
        silenceGap: TimeInterval = 0.6
    ) {
        self.maxCharactersPerLine = max(1, maxCharactersPerLine)
        self.maxLines = max(1, maxLines)
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.silenceGap = silenceGap
    }

    public var maxCharacters: Int { maxCharactersPerLine * maxLines }

    public static let `default` = CaptionSplitOptions()
}
