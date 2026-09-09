import Foundation

/// iTT (iTunes Timed Text) output — the caption format Final Cut Pro exports and imports natively.
///
/// This exists because SubRip cannot say what language it is in. Captions imported from a `.srt`
/// land in Final Cut Pro tagged **English** whatever they actually say; an iTT file carries
/// `xml:lang` on its root, so Korean captions arrive as Korean. It is also frame-exact where SRT
/// is millisecond-approximate: times here are SMPTE timecodes counted in frames.
///
/// The structure is copied from a real export (`Fixtures/caption_korean.itt`), not from the TTML
/// specification — the same rule as everything else FCP-facing.
public struct ITTWriter: Sendable {
    /// Goes on the root as `xml:lang`. This is the whole reason the format is worth writing.
    public var language: String

    public init(language: String = "ko") {
        self.language = language
    }

    /// - Parameters:
    ///   - captions: times relative to the start of the timeline the captions will land on.
    ///   - frameDuration: the *sequence's* frame duration, which sets the timecode grid.
    ///   - dropFrame: from the sequence's `tcFormat`. Final Cut Pro writes `nonDrop` for NDF.
    public func string(
        from captions: [Caption],
        frameDuration: FCPTime,
        dropFrame: Bool = false
    ) -> String {
        let rate = TimecodeRate(frameDuration: frameDuration)
        let paragraphs = captions.map { caption in
            let text = caption.lines.joined(separator: "<br/>")
            return """
                  <p begin="\(rate.timecode(caption.start))" end="\(rate.timecode(caption.end))" \
            region="bottom">\(Self.escape(text))<br/></p>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0"?>
        <tt xmlns="http://www.w3.org/ns/ttml" \
        xmlns:tt="http://www.w3.org/ns/ttml" \
        xmlns:ttm="http://www.w3.org/ns/ttml#metadata" \
        xmlns:ttp="http://www.w3.org/ns/ttml#parameter" \
        xmlns:tts="http://www.w3.org/ns/ttml#styling" \
        xml:lang="\(language)" \
        ttp:dropMode="\(dropFrame ? "dropNTSC" : "nonDrop")" \
        ttp:frameRate="\(rate.nominal)" \
        ttp:frameRateMultiplier="\(rate.multiplierNumerator) \(rate.multiplierDenominator)" \
        ttp:timeBase="smpte">
          <head>
            <styling>
              <style xml:id="normal" tts:color="white" tts:fontFamily="sansSerif" tts:fontSize="100%" tts:fontStyle="normal" tts:fontWeight="normal"/>
            </styling>
            <layout>
              <region xml:id="bottom" tts:displayAlign="after" tts:extent="100% 15%" tts:origin="0% 85%" tts:writingMode="lrtb"/>
            </layout>
          </head>
          <body tts:color="white" region="bottom" style="normal">
            <div>
        \(paragraphs)
            </div>
          </body>
        </tt>

        """
    }

    static func escape(_ text: String) -> String {
        // `<br/>` is inserted by us and must survive, so the joined string is escaped before the
        // breaks go in — see `string(from:)`, which joins after escaping each line.
        text
    }
}

/// The timecode grid an iTT file counts in.
///
/// SMPTE timecode counts **nominal** frames: a 59.94 fps sequence is written as `frameRate="60"`
/// with `frameRateMultiplier="1000 1001"`, and a caption 3.003 seconds long ends at `00:00:03:00`.
/// Counting real frames instead would drift by a frame every thousand.
struct TimecodeRate {
    let frameDuration: FCPTime
    /// Frames per second as timecode counts them: 24, 25, 30, 60…
    let nominal: Int
    let multiplierNumerator: Int
    let multiplierDenominator: Int

    init(frameDuration: FCPTime) {
        self.frameDuration = frameDuration
        let exact = Double(frameDuration.denominator) / Double(frameDuration.numerator)
        let nominal = max(1, Int(exact.rounded()))
        self.nominal = nominal
        // 1000/1001 pulldown (23.976, 29.97, 59.94…) against a whole-number rate.
        if abs(exact - Double(nominal) * 1000.0 / 1001.0) < 0.001 {
            multiplierNumerator = 1000
            multiplierDenominator = 1001
        } else {
            multiplierNumerator = 1
            multiplierDenominator = 1
        }
    }

    /// `HH:MM:SS:FF`, non-drop.
    func timecode(_ seconds: TimeInterval) -> String {
        let totalFrames = max(0, Int((seconds / frameDuration.seconds).rounded()))
        let (hours, afterHours) = totalFrames.quotientAndRemainder(dividingBy: nominal * 3600)
        let (minutes, afterMinutes) = afterHours.quotientAndRemainder(dividingBy: nominal * 60)
        let (secondsPart, frames) = afterMinutes.quotientAndRemainder(dividingBy: nominal)
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, secondsPart, frames)
    }
}
