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

/// A title's box is not `text-style`'s background: the Subtitle template draws its own, 85%
/// opaque, and a transparent `backgroundColor` left it on screen in real Final Cut Pro
/// (2026-10-13). The box goes only when the template's Background Opacity parameter is 0 — which is
/// what `Fixtures/title_no_background.fcpxml` records, cleared by hand in FCP's inspector.
struct TitleBackgroundTests {
    let reader = FCPXMLReader()

    /// The parameter exactly as Final Cut Pro wrote it.
    private func referenceParam() throws -> XMLElement {
        let xml = try XMLDocument(data: try Fixture.data("title_no_background.fcpxml"))
        let params = try xml.nodes(forXPath: "//title/param[@name='Background Opacity']")
        return try #require(params.first as? XMLElement)
    }

    private func titles(drawsBackground: Bool) throws -> [XMLElement] {
        var style = CaptionStyle.default
        style.drawsBackground = drawsBackground
        let data = try Fixture.withoutCaptions("caption_one_clip.fcpxml")
        let clip = try #require(try reader.read(data: data).clips.first)
        let written = try FCPXMLWriter(style: style, form: .title).addingCaptions([
            Caption(lines: ["하나"], start: 1, end: 3),
            Caption(lines: ["둘"], start: 4, end: 6),
        ], to: clip, inDocument: data)
        return try XMLDocument(data: written).nodes(forXPath: "//title").compactMap { $0 as? XMLElement }
    }

    @Test func noBackgroundWritesTheParameterFinalCutWrote() throws {
        let reference = try referenceParam()
        let written = try titles(drawsBackground: false)
        #expect(written.count == 2)
        for title in written {
            let param = try #require(title.elements(forName: "param").first)
            for attribute in ["name", "key", "value"] {
                #expect(param.attribute(forName: attribute)?.stringValue
                        == reference.attribute(forName: attribute)?.stringValue)
            }
        }
    }

    /// FCP puts parameters before `<text>`; the DTD requires it too.
    @Test func theParameterComesBeforeTheText() throws {
        for title in try titles(drawsBackground: false) {
            let names = title.children?.compactMap { ($0 as? XMLElement)?.name } ?? []
            #expect(names.first == "param")
            #expect(names.firstIndex(of: "param")! < names.firstIndex(of: "text")!)
        }
    }

    /// With a background, the template keeps its own default — as in `title_subtitle.fcpxml`, which
    /// carries no parameter at all.
    @Test func aBackgroundLeavesTheTemplateAlone() throws {
        for title in try titles(drawsBackground: true) {
            #expect(title.elements(forName: "param").isEmpty)
        }
    }

    /// Captions have no template, so nothing but `text-style` changes for them.
    @Test func captionsGetNoTemplateParameter() throws {
        var style = CaptionStyle.default
        style.drawsBackground = false
        let data = try Fixture.withoutCaptions("caption_one_clip.fcpxml")
        let clip = try #require(try reader.read(data: data).clips.first)
        let written = try FCPXMLWriter(style: style, form: .caption).addingCaptions(
            [Caption(lines: ["가"], start: 0, end: 1)], to: clip, inDocument: data)
        let xml = try XMLDocument(data: written)
        #expect(try xml.nodes(forXPath: "//caption/param").isEmpty)
    }

    @Test(.enabled(if: Fixture.DTD.isAvailable))
    func theReferenceExportValidates() throws {
        #expect(try Fixture.DTD.validate(try Fixture.data("title_no_background.fcpxml")) == nil)
    }

    @Test(.enabled(if: Fixture.DTD.isAvailable))
    func aTitleWithNoBackgroundValidates() throws {
        var style = CaptionStyle.default
        style.drawsBackground = false
        let data = try Fixture.withoutCaptions("caption_one_clip.fcpxml")
        let clip = try #require(try reader.read(data: data).clips.first)
        let written = try FCPXMLWriter(style: style, form: .both).addingCaptions(
            [Caption(lines: ["가"], start: 0, end: 1)], to: clip, inDocument: data)
        #expect(try Fixture.DTD.validate(written) == nil)
    }
}
