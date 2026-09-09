import Foundation

/// One caption unit: what goes on screen at once, as one or two lines.
public struct Caption: Sendable, Equatable {
    public var lines: [String]
    public var start: TimeInterval
    public var end: TimeInterval

    public init(lines: [String], start: TimeInterval, end: TimeInterval) {
        self.lines = lines
        self.start = start
        self.end = end
    }

    public var text: String { lines.joined(separator: "\n") }
    public var duration: TimeInterval { end - start }
}
