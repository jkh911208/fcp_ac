import Foundation
import Testing
@testable import FCPCaptionCore

/// "배경 없음" is a fully transparent background colour, not a separate setting — both formats
/// carry alpha, so there is nothing else to write and nothing else to keep in step.
struct CaptionStyleBackgroundTests {
    @Test func theDefaultHasABackground() {
        #expect(CaptionStyle.default.drawsBackground)
    }

    @Test func turningItOffWritesATransparentBackgroundToBothFormats() {
        var style = CaptionStyle.default
        style.drawsBackground = false

        let fcpxml = Dictionary(uniqueKeysWithValues: style.fcpxmlAttributes)
        #expect(fcpxml["backgroundColor"] == "0 0 0 0")
        let itt = Dictionary(uniqueKeysWithValues: style.ittAttributes)
        #expect(itt["tts:backgroundColor"] == "#00000000")
    }

    /// Unticking the box brings back the colour that was there, rather than resetting to black.
    @Test func turningItBackOnRestoresTheColourOpaque() {
        var style = CaptionStyle(backgroundColor: CaptionColor(red: 0.2, green: 0.4, blue: 0.6))
        style.drawsBackground = false
        style.drawsBackground = true
        #expect(style.backgroundColor == CaptionColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    }

    /// A half-transparent background chosen in the colour panel is still a background, and
    /// re-asserting "on" must not flatten it to opaque.
    @Test func aTranslucentBackgroundIsLeftAlone() {
        var style = CaptionStyle(backgroundColor: CaptionColor(red: 0, green: 0, blue: 0, alpha: 0.5))
        #expect(style.drawsBackground)
        style.drawsBackground = true
        #expect(style.backgroundColor.alpha == 0.5)
    }

    @Test func noBackgroundSurvivesBeingSaved() throws {
        var settings = FCPCaptionSettings()
        settings.style.drawsBackground = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(FCPCaptionSettings.self, from: data)
        #expect(decoded.style.drawsBackground == false)
    }

    /// Final Cut Pro has to accept the transparent colour, not just this code.
    @Test(.enabled(if: Fixture.DTD.isAvailable))
    func aCaptionWithNoBackgroundStillValidates() throws {
        var style = CaptionStyle.default
        style.drawsBackground = false
        let data = try Fixture.withoutCaptions("caption_one_clip.fcpxml")
        let clip = try #require(try FCPXMLReader().read(data: data).clips.first)
        let written = try FCPXMLWriter(style: style).addingCaptions(
            [Caption(lines: ["가"], start: 0, end: 1)], to: clip, inDocument: data)
        #expect(String(decoding: written, as: UTF8.self).contains("backgroundColor=\"0 0 0 0\""))
        #expect(try Fixture.DTD.validate(written) == nil)
    }
}
