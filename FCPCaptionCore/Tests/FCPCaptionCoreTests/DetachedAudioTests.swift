import Foundation
import Testing
@testable import FCPCaptionCore

/// Pinned to `Fixtures/detached_audio.fcpxml`, cut from a real Final Cut Pro project (2026-11-25)
/// in which sixteen detached-audio clips — 5.8 minutes of dialogue — got no captions: each is a
/// `<clip>` with no `ref`, so the reader found no file and skipped it with
/// "원본 미디어 경로를 찾지 못했습니다".
///
/// The spine holds three things, seven clips in all:
/// 1. a `<clip>` that is only a picture (`<video ref="r10">`), with its detached audio beneath it
///    as a `<clip lane="-1">` → `<gap>` → `<audio ref="r10">`;
/// 2. a muted action-cam `asset-clip` with another piece of that same detached audio beneath it;
/// 3. another muted action-cam clip carrying both halves of the detached clip: the audio on lane
///    -1 and the picture, shrunk to a picture-in-picture, on lane 1.
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
        #expect(all.count == 7)
        let audio = try detached
        #expect(audio.count == 3)
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
        // The same, connected as a picture-in-picture.
        let inset = try clips()[6]
        #expect(inset.lane == 1)
        #expect(inset.skipReason == .noAudio)
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

    // MARK: - Writing

    /// Writes one caption, 0.5–1.8s into `clip`, and returns the written document.
    private func write(
        to clip: ClipRef, in data: Data, form: FCPXMLWriter.Form = .caption
    ) throws -> FCPXMLWriter.WriteResult {
        try FCPXMLWriter(form: form).write(
            [Caption(lines: ["안녕하세요"], start: 0.5, end: 1.8)], to: clip, inDocument: data)
    }

    private func root(of data: Data) throws -> (XMLDocument, XMLElement) {
        // The document is returned too: a root element outlives a freed document, but `//`
        // XPath on it then fails with "invalid type".
        let document = try XMLDocument(data: data)
        return (document, try #require(document.rootElement()))
    }

    @Test("a detached-audio clip's captions go on the clip it hangs from, at the same moment")
    func captionsGoOnTheParent() throws {
        // Final Cut Pro drops anything anchored to a connected clip on import: in the real
        // project every title written to one vanished. Before this, the caption landed inside
        // the <clip lane="-1"> — valid by the DTD, and gone from the timeline.
        let data = try Fixture.data("detached_audio.fcpxml")
        let before = try clips(data)
        let detached = before[1]
        let written = try write(to: detached, in: data)
        #expect(written.written == 1)
        #expect(written.skipped == 0)

        let after = try clips(written.document)
        #expect(after[1].captions.isEmpty, "a caption inside a connected clip is dropped by FCP")
        let caption = try #require(after[0].captions.first)
        #expect(caption.text == "안녕하세요")
        // In the parent's time the detached clip starts at its own `offset`.
        #expect(abs((caption.offset - detached.offset).seconds - 0.5) < 0.02)
        // Nothing else moved: the same clips, captions aside.
        var unchanged = after
        for index in unchanged.indices { unchanged[index].captions = [] }
        #expect(unchanged == before)
    }

    @Test("a title for detached audio sits on the parent's own frame grid")
    func titleGridIsTheParents() throws {
        // The second detached clip hangs from a 29.97 action-cam clip; the audio itself is
        // 59.94. A title's position is checked against its parent's grid, its length against the
        // 60p sequence's.
        let data = try Fixture.data("detached_audio.fcpxml")
        let written = try write(to: try clips(data)[3], in: data, form: .title)
        let (document, root) = try root(of: written.document)
        defer { withExtendedLifetime(document) {} }
        #expect(try root.nodes(forXPath: "//clip[@lane='-1']/title").isEmpty)
        let title = try #require(try root.nodes(forXPath: "//spine/asset-clip/title").first as? XMLElement)
        // Nothing else is connected above this parent, so lane 1 is free.
        #expect(title.attribute(forName: "lane")?.stringValue == "1")
        let offset = try FCPTime.parse(try #require(title.attribute(forName: "offset")?.stringValue))
        let duration = try FCPTime.parse(try #require(title.attribute(forName: "duration")?.stringValue))
        #expect(offset.aligned(to: FCPTime(1001, 30000)) == offset)
        #expect(duration.aligned(to: FCPTime(100, 6000)) == duration)
    }

    @Test("captions past the end of the parent are skipped and counted")
    func captionsPastTheParentAreCounted() throws {
        // Shorten the parent to one second: the caption at 0.5–1.8s is trimmed to its end, and
        // one starting at 3s has no place to anchor.
        let data = try edited { root in
            try shift("//spine/clip", "duration", in: root) { _ in FCPTime(1, 1) }
        }
        let detached = try clips(data)[1]
        let written = try FCPXMLWriter().write(
            [Caption(lines: ["안녕하세요"], start: 0.5, end: 1.8),
             Caption(lines: ["반갑습니다"], start: 3, end: 4)],
            to: detached, inDocument: data)
        #expect(written.written == 1)
        #expect(written.skipped == 1)
        let parent = try clips(written.document)[0]
        let caption = try #require(parent.captions.first)
        #expect(caption.offset + caption.duration <= parent.start + parent.duration)
    }

    @Test("a title goes above a picture-in-picture on the same parent, a caption is unaffected")
    func titleClearsThePictureInPicture() throws {
        // Seen in Final Cut Pro: titles on lane 1 next to a picture-in-picture on lane 1 showed in
        // the timeline and never in the viewer.
        let data = try Fixture.data("detached_audio.fcpxml")
        let written = try write(to: try clips(data)[5], in: data, form: .both)
        #expect(written.written == 1)
        let (document, root) = try root(of: written.document)
        defer { withExtendedLifetime(document) {} }
        let parent = try #require(try root.nodes(forXPath: "//spine/asset-clip[2]").first as? XMLElement)
        let title = try #require(parent.elements(forName: "title").first)
        #expect(title.attribute(forName: "lane")?.stringValue == "2")
        // Captions have lanes of their own, which no connected clip occupies.
        let caption = try #require(parent.elements(forName: "caption").first)
        #expect(caption.attribute(forName: "lane")?.stringValue == "1")
    }

    @Test("a title on a spine clip goes above its connected b-roll")
    func titleClearsBRollOnTheSpine() throws {
        // `retimed_and_connected.fcpxml`: spine clip "03" has a <video lane="1"> over it, and a
        // synced mic, "01-8", on lane -1 beneath it.
        let data = try Fixture.data("retimed_and_connected.fcpxml")
        let clips = try FCPXMLReader().read(data: data).clips
        let index = try #require(clips.firstIndex { $0.name == "01-8" })
        let written = try write(to: clips[index], in: data, form: .title)
        let (document, root) = try root(of: written.document)
        defer { withExtendedLifetime(document) {} }
        let title = try #require(try root.nodes(forXPath: "//spine/*/title").first as? XMLElement)
        let parent = try #require(title.parent as? XMLElement)
        #expect(parent.elements(forName: "video").first?.attribute(forName: "lane")?.stringValue == "1")
        #expect(title.attribute(forName: "lane")?.stringValue == "2")
    }

    @Test("an ordinary connected clip's captions also go on its parent")
    func ordinaryConnectedClip() throws {
        // `retimed_and_connected.fcpxml`: a synced mic, an asset-clip on lane -1 under the
        // spine clip "03".
        let data = try Fixture.data("retimed_and_connected.fcpxml")
        let before = try FCPXMLReader().read(data: data).clips
        let index = try #require(before.firstIndex { $0.lane == -1 && $0.isCaptionable })
        let written = try write(to: before[index], in: data)
        #expect(written.written == 1)
        let after = try FCPXMLReader().read(data: written.document).clips
        #expect(after[index].captions.isEmpty)
        let parent = try #require(after[..<index].last { $0.lane == nil })
        let caption = try #require(parent.captions.first)
        #expect(abs((caption.offset - before[index].offset).seconds - 0.5) < 0.02)
    }

    @Test("a clip on the spine still carries its own captions")
    func spineClipIsUnchanged() throws {
        let data = try Fixture.data("detached_audio.fcpxml")
        var clip = try clips(data)[2]
        clip.skipReason = nil   // muted in the fixture; the writer does not care
        let written = try write(to: clip, in: data)
        let after = try clips(written.document)
        #expect(after[2].captions.count == 1)
        #expect(abs((try #require(after[2].captions.first).offset - clip.start).seconds - 0.5) < 0.02)
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
        for clip in try clips(data).filter({ $0.lane == -1 }) {
            let written = try write(to: clip, in: data, form: .both)
            #expect(written.written == 1)
            #expect(try Fixture.DTD.validate(written.document) == nil)
        }
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
