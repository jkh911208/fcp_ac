import Foundation
import Testing
@testable import FCPCaptionCore

/// Pinned to `Fixtures/detached_audio.fcpxml`, cut from a real Final Cut Pro project (2026-11-25)
/// in which sixteen detached-audio clips — 5.8 minutes of dialogue — got no captions: each is a
/// `<clip>` with no `ref`, so the reader found no file and skipped it with
/// "원본 미디어 경로를 찾지 못했습니다".
///
/// The spine holds two things, four clips in all:
/// 1. a `<clip>` that is only a picture (`<video ref="r10">`), with its detached audio beneath it
///    as a `<clip lane="-1">` → `<gap>` → `<audio ref="r10">`;
/// 2. a muted action-cam `asset-clip` with another piece of that same detached audio beneath it.
@Suite("detached audio")
struct DetachedAudioTests {
    private static let audioFile = "DJI_20261107214743_0004_D.MP4"
    private static let assetStart = FCPTime(4303855556, 60000)

    private func clips(_ data: Data? = nil) throws -> [ClipRef] {
        try FCPXMLReader().read(data: data ?? Fixture.data("detached_audio.fcpxml")).clips
    }

    /// The fixture with one change made through the DOM, so the clip XML itself stays FCP's.
    private func edited(_ change: (XMLElement) throws -> Void) throws -> Data {
        let document = try XMLDocument(
            data: try Fixture.data("detached_audio.fcpxml"), options: [.nodePreserveWhitespace])
        try change(try #require(document.rootElement()))
        document.isStandalone = false
        return document.xmlData(options: [.nodePrettyPrint])
    }

    private func elements(_ xpath: String, in root: XMLElement) throws -> [XMLElement] {
        let found = try root.nodes(forXPath: xpath).compactMap { $0 as? XMLElement }
        try #require(!found.isEmpty, "nothing at \(xpath)")
        return found
    }

    /// Sets a time attribute on every element at `xpath` by applying `change` to its value.
    private func shift(_ xpath: String, _ attribute: String, in root: XMLElement, _ change: (FCPTime) -> FCPTime) throws {
        for element in try elements(xpath, in: root) {
            let raw = try #require(element.attribute(forName: attribute)?.stringValue)
            element.attribute(forName: attribute)?.stringValue = change(try FCPTime.parse(raw)).description
        }
    }

    private var detached: [ClipRef] {
        get throws { try clips().filter { $0.lane == -1 } }
    }

    @Test("both detached-audio clips are read, and both find the camera file")
    func findsTheDetachedAudiosFile() throws {
        let all = try clips()
        #expect(all.count == 4)
        let audio = try detached
        #expect(audio.count == 2)
        for clip in audio {
            #expect(clip.element == "clip")
            #expect(clip.assetID == "")
            #expect(clip.isCaptionable, "skipped: \(String(describing: clip.skipReason))")
            #expect(clip.hasAudio)
            #expect(clip.mediaURL?.lastPathComponent == Self.audioFile)
            #expect(clip.assetFrameDuration == FCPTime(1001, 60000))
            #expect(clip.audibleDuration == clip.duration)
        }
    }

    @Test("the position in the file is the clip's start minus the camera's timecode origin")
    func mapsWrapperTimeIntoTheFile() throws {
        // Every layer in the real export has offset == start, so the wrapper's time is the
        // asset's time, and the file position is simply start - the asset's start.
        let audio = try detached
        #expect(audio[0].start - audio[0].assetStart == FCPTime(2205362159, 30000) - Self.assetStart)
        #expect(abs(audio[0].mediaStartSeconds - 1781.1461) < 0.001)
        #expect(abs(audio[1].mediaStartSeconds - 1813.7120) < 0.001)
    }

    @Test("the picture half of a detached clip has no audio, and says so")
    func pictureHalfHasNoAudio() throws {
        let picture = try #require(try clips().first)
        #expect(picture.element == "clip")
        #expect(picture.lane == nil)
        #expect(picture.skipReason == .noAudio)
        #expect(!picture.hasAudio)
    }

    @Test("a muted parent stays muted, and does not mute the audio detached beneath it")
    func mutedParent() throws {
        let all = try clips()
        #expect(all[2].element == "asset-clip")
        #expect(all[2].skipReason == .silenced)
        #expect(all[3].isCaptionable)
    }

    @Test("a muted detached-audio clip is skipped as muted")
    func mutedWrapper() throws {
        let data = try edited { root in
            for volume in try elements("//clip[@lane='-1']/adjust-volume", in: root) {
                volume.attribute(forName: "amount")?.stringValue = "-96dB"
            }
        }
        #expect(try clips(data).filter { $0.lane == -1 }.allSatisfy { $0.skipReason == .silenced })
    }

    @Test("the audio's own start moves the position in the file")
    func audioStartIsApplied() throws {
        // Play material ten seconds later than the gap position it is anchored at.
        let data = try edited { root in
            try shift("//clip[@lane='-1']/gap/audio", "start", in: root) { $0 + FCPTime(10, 1) }
        }
        let before = try detached[0].mediaStartSeconds
        let after = try #require(try clips(data).first { $0.lane == -1 }).mediaStartSeconds
        #expect(abs(after - before - 10) < 0.0001)
    }

    @Test("the gap's own time base moves the position in the file")
    func gapTimeBaseIsApplied() throws {
        // A gap placed five seconds earlier in the wrapper with the same start reads the
        // wrapper's time five seconds later in its own — and so does everything anchored to it.
        let data = try edited { root in
            try shift("//clip[@lane='-1']/gap", "offset", in: root) { $0 - FCPTime(5, 1) }
        }
        let before = try detached[0].mediaStartSeconds
        let after = try #require(try clips(data).first { $0.lane == -1 }).mediaStartSeconds
        #expect(abs(after - before - 5) < 0.0001)
    }

    @Test("audio that only begins after the clip starts is skipped, and says why")
    func audioStartsAfterTheClip() throws {
        let data = try edited { root in
            try shift("//spine/clip/clip[@lane='-1']/gap/audio", "offset", in: root) { _ in
                FCPTime(2205362159, 30000) + FCPTime(1, 1)
            }
        }
        let clip = try #require(try clips(data).first { $0.lane == -1 })
        #expect(clip.skipReason == .wrappedAudioUnreadable)
        #expect(clip.skipReason?.korean.hasSuffix("니다") == true)
    }

    @Test("audio that ends early limits what is transcribed")
    func audioEndsEarly() throws {
        // Anchored at the gap's start, three seconds past where the clip starts is
        // (clip start - gap start) + 3s of audio.
        let clipStart = FCPTime(2205362159, 30000)
        let data = try edited { root in
            try shift("//spine/clip/clip[@lane='-1']/gap/audio", "duration", in: root) { _ in
                clipStart - Self.assetStart + FCPTime(3, 1)
            }
        }
        let clip = try #require(try clips(data).first { $0.lane == -1 })
        #expect(clip.isCaptionable)
        #expect(clip.audibleDuration == FCPTime(3, 1))
    }

    @Test("a wrapper whose audio has no start is skipped rather than guessed")
    func missingStartIsNotGuessed() throws {
        let data = try edited { root in
            for audio in try elements("//spine/clip/clip[@lane='-1']/gap/audio", in: root) {
                audio.removeAttribute(forName: "start")
            }
        }
        let clip = try #require(try clips(data).first { $0.lane == -1 })
        #expect(clip.skipReason == .wrappedAudioUnreadable)
    }

    @Test("captions written to a detached-audio clip read back on that clip")
    func roundTrip() throws {
        let data = try Fixture.data("detached_audio.fcpxml")
        let clip = try #require(try clips(data).first { $0.lane == -1 })
        let written = try FCPXMLWriter().write(
            [Caption(lines: ["안녕하세요"], start: 0.5, end: 1.8)], to: clip, inDocument: data)
        #expect(written.written == 1)

        let reread = try clips(written.document)
        let target = try #require(reread.first { $0.lane == -1 })
        #expect(target.isCaptionable)
        #expect(target.mediaURL == clip.mediaURL)
        let caption = try #require(target.captions.first)
        #expect(caption.text == "안녕하세요")
        #expect(abs((caption.offset - clip.start).seconds - 0.5) < 0.02)
        // Nothing else moved: the same clips, captions aside.
        var unchanged = reread
        for index in unchanged.indices { unchanged[index].captions = [] }
        #expect(unchanged == (try clips(data)))
    }

    @Test("two identical wrappers are an error, not a coin toss")
    func ambiguousWrapperIsAnError() throws {
        let data = try edited { root in
            let wrapper = try #require(try elements("//spine/clip/clip[@lane='-1']", in: root).first)
            wrapper.parent.flatMap { $0 as? XMLElement }?.addChild(try #require(wrapper.copy() as? XMLElement))
        }
        let clip = try #require(try clips(data).first { $0.lane == -1 })
        #expect(throws: FCPXMLError.clipNotFound(clip.name)) {
            try FCPXMLWriter().write([Caption(lines: ["안녕하세요"], start: 0.5, end: 1.8)], to: clip, inDocument: data)
        }
    }

    @Test(.enabled(if: Fixture.DTD.isAvailable(version: "1.15")))
    func writtenDocumentIsValid() throws {
        let data = try Fixture.data("detached_audio.fcpxml")
        #expect(try Fixture.DTD.validate(data) == nil)
        let clip = try #require(try clips(data).first { $0.lane == -1 })
        let written = try FCPXMLWriter(form: .both).write(
            [Caption(lines: ["안녕하세요"], start: 0.5, end: 1.8)], to: clip, inDocument: data)
        #expect(try Fixture.DTD.validate(written.document) == nil)
    }

    @Test("the fixture carries no bookmark, no real path and none of the user's transcript")
    func fixtureIsScrubbed() throws {
        let text = String(decoding: try Fixture.data("detached_audio.fcpxml"), as: UTF8.self)
        #expect(!text.contains("<bookmark>"))
        #expect(!text.contains("/Volumes/"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("<title"))
        #expect(!text.contains("<caption"))
    }
}
