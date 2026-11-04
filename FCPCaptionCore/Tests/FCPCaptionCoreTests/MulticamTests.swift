import Foundation
import Testing
@testable import FCPCaptionCore

/// Pinned to `Fixtures/multicam.fcpxml`, cut from a real Final Cut Pro project (2026-11-04) in
/// which every multicam clip failed with "원본 미디어 경로를 찾지 못했습니다": an `mc-clip`'s `ref`
/// names a `<media>`, not an `<asset>`, so the reader found no file at all.
///
/// The multicam has two angles. Angle A (`J1Qn…`) is one camera file from multicam time 0 to
/// 2136.70s; angle B (`4fXw…`) is a 662.63s gap, then a second camera file. Every clip on the
/// spine takes its audio from A.
@Suite("multicam clips")
struct MulticamTests {
    private static let angleA = "J1QnzU8QQiiAnwIVFhG3mg"
    private static let angleB = "4fXwFsuWRN+GMBurHeWdSA"
    private static let tcStart = FCPTime(282424142, 60000)

    private func clips(_ data: Data? = nil) throws -> [ClipRef] {
        try FCPXMLReader().read(data: data ?? Fixture.data("multicam.fcpxml")).clips
    }

    /// The fixture with one change made through the DOM, so the clip XML itself stays FCP's.
    private func edited(_ change: (XMLElement) throws -> Void) throws -> Data {
        let document = try XMLDocument(data: try Fixture.data("multicam.fcpxml"), options: [.nodePreserveWhitespace])
        try change(try #require(document.rootElement()))
        document.isStandalone = false
        return document.xmlData(options: [.nodePrettyPrint])
    }

    private func element(_ xpath: String, in root: XMLElement) throws -> XMLElement {
        try #require(try root.nodes(forXPath: xpath).first as? XMLElement)
    }

    @Test("every multicam clip on the spine finds the file its audio comes from")
    func findsTheAudioAnglesFile() throws {
        let all = try clips()
        #expect(all.count == 3)
        for clip in all {
            #expect(clip.element == "mc-clip")
            #expect(clip.isCaptionable, "skipped: \(String(describing: clip.skipReason))")
            #expect(clip.mediaURL?.lastPathComponent == "DJI_20260919122453_0150_D.MP4")
            #expect(clip.hasAudio)
        }
    }

    @Test("the position inside the file is the clip's start minus the multicam's tcStart")
    func mapsMulticamTimeIntoTheFile() throws {
        let first = try #require(try clips().first)
        // Angle A sits at offset 0 and starts at its asset's own start, so the file position is
        // exactly how far into the multicam the clip starts: 741.59s.
        #expect(first.start - first.assetStart == FCPTime(326919593, 60000) - Self.tcStart)
        #expect(abs(first.mediaStartSeconds - 741.5908) < 0.001)
        #expect(first.audibleDuration == first.duration)
    }

    @Test("a clip cut to angle B's picture still takes angle A's sound")
    func splitAudioAndVideoFollowsTheAudioAngle() throws {
        let second = try clips()[1]
        // The video angle's file is DJI_…0003_D; transcribing that would caption the wrong mic.
        #expect(second.mediaURL?.lastPathComponent == "DJI_20260919122453_0150_D.MP4")
    }

    @Test("captions follow the sequence, titles follow the multicam's own 59.94 grid")
    func frameDurations() throws {
        let document = try FCPXMLReader().read(data: Fixture.data("multicam.fcpxml"))
        #expect(document.frameDuration == FCPTime(100, 6000))
        #expect(try #require(document.clips.first).assetFrameDuration == FCPTime(1001, 60000))
    }

    @Test("an angle that starts after a gap is offset by that gap")
    func angleAfterAGap() throws {
        // Switch the second clip's audio to angle B. 747.40s into the multicam is 84.78s into
        // angle B's file, because B's camera only starts at 662.63s.
        let data = try edited { root in
            for source in try root.nodes(forXPath: "//spine/mc-clip[2]/mc-source").compactMap({ $0 as? XMLElement }) {
                let isB = source.attribute(forName: "angleID")?.stringValue == Self.angleB
                source.attribute(forName: "srcEnable")?.stringValue = isB ? "audio" : "video"
            }
        }
        let clip = try clips(data)[1]
        #expect(clip.isCaptionable)
        #expect(clip.mediaURL?.lastPathComponent == "DJI_20260919124032_0003_D.MP4")
        let expected = FCPTime(163634471, 30000) - Self.tcStart - FCPTime(39757718, 60000)
        #expect(clip.start - clip.assetStart == expected)
        #expect(abs(clip.mediaStartSeconds - 84.7848) < 0.001)
    }

    @Test("a clip whose audio angle is a gap where it starts is skipped, and says why")
    func audioAngleInAGap() throws {
        // The browser's whole-multicam clip starts at multicam time 0, where angle B is a gap.
        let data = try edited { root in
            let spine = try element("//spine", in: root)
            let browser = try element("library/event/mc-clip", in: root)
            browser.detach()
            try element("mc-source", in: browser).attribute(forName: "angleID")?.stringValue = Self.angleB
            spine.addChild(browser)
        }
        let clip = try #require(try clips(data).last)
        #expect(clip.skipReason == .multicamAngleUnreadable)
        #expect(clip.skipReason?.korean.hasSuffix("니다") == true)
    }

    @Test("a clip longer than its audio angle transcribes only the part with sound")
    func clipPastTheEndOfItsAngle() throws {
        // The whole multicam runs 2344.58s, to the end of angle B; angle A stops at 2136.70s.
        let data = try edited { root in
            let browser = try element("library/event/mc-clip", in: root)
            browser.detach()
            try element("//spine", in: root).addChild(browser)
        }
        let clip = try #require(try clips(data).last)
        #expect(clip.start == Self.tcStart)
        #expect(clip.mediaStartSeconds == 0)
        #expect(clip.duration == FCPTime(140674534, 60000))
        #expect(clip.audibleDuration == FCPTime(128202074, 60000))
    }

    @Test("a clip with no angle switched to audio is reported as having no audio")
    func noAudioAngle() throws {
        let data = try edited { root in
            try element("//spine/mc-clip[1]/mc-source", in: root)
                .attribute(forName: "srcEnable")?.stringValue = "video"
        }
        let clip = try #require(try clips(data).first)
        #expect(clip.skipReason == .noAudio)
        #expect(!clip.hasAudio)
    }

    @Test("a muted multicam clip stays muted whatever its angle holds")
    func mutedClip() throws {
        let data = try edited { root in
            try element("//spine/mc-clip[1]/adjust-volume", in: root)
                .attribute(forName: "amount")?.stringValue = "-96dB"
        }
        #expect(try #require(try clips(data).first).skipReason == .silenced)
    }

    @Test("captions written to a multicam clip read back at the same multicam times")
    func roundTrip() throws {
        let data = try Fixture.data("multicam.fcpxml")
        let clip = try #require(try clips(data).first)
        let written = try FCPXMLWriter().write(
            [Caption(lines: ["안녕하세요"], start: 0.5, end: 1.8)], to: clip, inDocument: data)
        #expect(written.written == 1)

        let reread = try #require(try clips(written.document).first)
        #expect(reread.isCaptionable)
        #expect(reread.mediaURL == clip.mediaURL)
        let caption = try #require(reread.captions.first)
        #expect(caption.text == "안녕하세요")
        #expect(abs((caption.offset - clip.start).seconds - 0.5) < 0.02)
        // Nothing else moved: reading the written document gives the same clips, captions aside.
        var unchanged = try clips(written.document)
        unchanged[0].captions = []
        #expect(unchanged == (try clips(data)))
    }

    @Test("titles on a multicam clip land where Final Cut Pro puts its own")
    func titleGrids() throws {
        let data = try Fixture.data("multicam.fcpxml")
        let clip = try #require(try clips(data).first)
        let written = try FCPXMLWriter(form: .title).write(
            [Caption(lines: ["안녕하세요"], start: 0.5, end: 1.8)], to: clip, inDocument: data)
        // Held in its own constant: a root element outlives a freed document, but `//` XPath on
        // it then fails with "invalid type".
        let document = try XMLDocument(data: written.document)
        let root = try #require(document.rootElement())
        let title = try element("//spine/mc-clip[1]/title", in: root)
        let offset = try FCPTime.parse(try #require(title.attribute(forName: "offset")?.stringValue))
        let duration = try FCPTime.parse(try #require(title.attribute(forName: "duration")?.stringValue))
        // In the source project all 146 titles on multicam clips had offsets on 1001/60000 and
        // durations on the 60p sequence's 100/6000.
        #expect(offset.aligned(to: FCPTime(1001, 60000)) == offset)
        #expect(duration.aligned(to: FCPTime(100, 6000)) == duration)
    }

    @Test(.enabled(if: Fixture.DTD.isAvailable))
    func writtenDocumentIsValid() throws {
        let data = try Fixture.data("multicam.fcpxml")
        let clip = try #require(try clips(data).first)
        let written = try FCPXMLWriter(form: .both).write(
            [Caption(lines: ["안녕하세요"], start: 0.5, end: 1.8)], to: clip, inDocument: data)
        #expect(try Fixture.DTD.validate(written.document) == nil)
    }

    @Test("the fixture carries no bookmark, no real path and none of the user's transcript")
    func fixtureIsScrubbed() throws {
        let text = String(decoding: try Fixture.data("multicam.fcpxml"), as: UTF8.self)
        #expect(!text.contains("<bookmark>"))
        #expect(!text.contains("/Volumes/"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("<title"))
    }
}
