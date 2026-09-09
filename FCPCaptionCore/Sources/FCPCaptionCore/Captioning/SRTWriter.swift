import Foundation

/// SubRip output. Used by the CLI spike and as the §10 fallback when FCPXML import can't reach an
/// already-open project.
public enum SRTWriter {
    public static func string(from captions: [Caption]) -> String {
        captions.enumerated().map { index, caption in
            // Each block ends with a blank line — that separator is what makes it SubRip.
            "\(index + 1)\n"
                + "\(timecode(caption.start)) --> \(timecode(caption.end))\n"
                + "\(caption.text)\n\n"
        }
        .joined()
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let milliseconds = Int((clamped * 1000).rounded())
        let (hours, remainderH) = milliseconds.quotientAndRemainder(dividingBy: 3_600_000)
        let (minutes, remainderM) = remainderH.quotientAndRemainder(dividingBy: 60_000)
        let (secs, millis) = remainderM.quotientAndRemainder(dividingBy: 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}
