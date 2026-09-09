import Foundation
import Testing
@testable import FCPCaptionCore

struct FCPXMLWriterTests {
    let reader = FCPXMLReader()
    let writer = FCPXMLWriter()

    /// The reference export with the editor's caption removed: the ordinary case of a clip that
    /// has no captions yet. Collisions with existing captions have their own suite.
    private func fixture() throws -> (data: Data, document: FCPXMLDocument, clip: ClipRef) {
        let data = try Fixture.withoutCaptions("caption_one_clip.fcpxml")
        let document = try reader.read(data: data)
        return (data, document, try #require(document.clips.first))
    }

    private func write(_ captions: [Caption]) throws -> (data: Data, clip: ClipRef) {
        let (data, _, clip) = try fixture()
        let written = try writer.addingCaptions(captions, to: clip, inDocument: data)
        let reread = try reader.read(data: written)
        return (written, try #require(reread.clips.first))
    }

    // The round trip that matters: our captions go in, and come back out of the reader as the
    // same times and text.
    @Test func capturesTimesAndTextThroughARoundTrip() throws {
        let (_, clip) = try write([
            Caption(lines: ["안녕하세요"], start: 0, end: 2),
            Caption(lines: ["오늘은 날씨가", "정말 좋네요"], start: 2.5, end: 5),
        ])

        #expect(clip.captions.count == 2)

        let second = try #require(clip.captions.last)
        #expect(second.text == "오늘은 날씨가\n정말 좋네요")
        #expect(second.role == "iTT?captionFormat=ITT.ko")
        #expect(abs(second.offset.seconds - 2.5) < 0.02)
        #expect(abs((second.offset + second.duration).seconds - 5) < 0.02)
    }

    @Test func everyWrittenTimeLandsOnAWholeFrame() throws {
        let frame = FCPTime(1001, 60000)
        // Deliberately off-grid times, the kind transcription produces.
        let (_, clip) = try write([
            Caption(lines: ["하나"], start: 0.123456, end: 1.98765),
            Caption(lines: ["둘"], start: 2.001, end: 3.9),
        ])
        for caption in clip.captions {
            #expect(caption.offset == caption.offset.aligned(to: frame, rounding: .nearest))
            #expect(caption.duration == caption.duration.aligned(to: frame, rounding: .nearest))
            #expect(caption.duration.frameCount(at: frame) >= 1)
        }
    }

    // Start rounds down, end rounds up — quantization may show a caption early and hold it long,
    // never clip a word. Half a frame either side proves the direction.
    @Test func roundingNeverCutsAWordOff() throws {
        let frame = FCPTime(1001, 60000)
        let halfFrame = frame.seconds / 2
        let (_, clip) = try write([Caption(lines: ["가"], start: 1 + halfFrame, end: 2 + halfFrame)])
        let written = try #require(clip.captions.last)
        #expect(written.offset.seconds <= 1 + halfFrame)
        #expect((written.offset + written.duration).seconds >= 2 + halfFrame)
    }

    @Test func captionsPastTheEndOfTheClipAreDropped() throws {
        let clipDuration = try fixture().clip.duration.seconds   // 24.54s
        let (_, clip) = try write([
            Caption(lines: ["안에"], start: 1, end: 2),
            Caption(lines: ["밖에"], start: clipDuration + 5, end: clipDuration + 8),
        ])
        #expect(clip.captions.count == 1)   // only the one that fits
        #expect(clip.captions.allSatisfy { ($0.offset + $0.duration).seconds <= clipDuration + 0.001 })
    }

    @Test func captionsStraddlingTheEndAreTrimmedToIt() throws {
        let clipDuration = try fixture().clip.duration.seconds
        let (_, clip) = try write([Caption(lines: ["걸침"], start: clipDuration - 1, end: clipDuration + 3)])
        let written = try #require(clip.captions.last)
        #expect((written.offset + written.duration).seconds <= clipDuration + 0.001)
        #expect(written.duration.seconds > 0)
    }

    @Test func captionOffsetsAreRelativeToTheClipsMediaStart() throws {
        // A clip that plays from 10s into its media: a caption 2s into the transcript belongs at
        // 12s in the clip's own time base, not at 2s.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.14">
          <resources>
            <format id="r1" frameDuration="1001/30000s"/>
            <asset id="r2" name="Interview" start="0s" duration="600s" format="r1" hasAudio="1"/>
          </resources>
          <library><event name="E"><project name="P">
            <sequence format="r1" duration="60s" tcStart="0s"><spine>
              <asset-clip ref="r2" offset="0s" name="Interview" start="10s" duration="60s"/>
            </spine></sequence>
          </project></event></library>
        </fcpxml>
        """
        let data = Data(xml.utf8)
        let clip = try #require(try reader.read(data: data).clips.first)
        let written = try writer.addingCaptions([Caption(lines: ["시작"], start: 2, end: 4)], to: clip, inDocument: data)
        let caption = try #require(try reader.read(data: written).clips.first?.captions.first)
        #expect(abs(caption.offset.seconds - 12) < 0.05)
    }

    @Test func theDocumentsOwnVersionIsPreserved() throws {
        let (data, _, clip) = try fixture()
        let written = try writer.addingCaptions([Caption(lines: ["가"], start: 0, end: 1)], to: clip, inDocument: data)
        #expect(try reader.read(data: written).version == "1.14")
        #expect(String(decoding: written, as: UTF8.self).contains("<!DOCTYPE fcpxml>"))
    }

    @Test func styleIdentifiersDoNotCollideWithTheOnesFinalCutWrote() throws {
        // The real export, not the stripped one: it already defines ts1 and ts2, which is the
        // whole point. Our captions go clear of its caption in time.
        let data = try Fixture.data("caption_one_clip.fcpxml")
        let clip = try #require(try reader.read(data: data).clips.first)
        let written = try writer.addingCaptions([
            Caption(lines: ["가"], start: 4, end: 5),
            Caption(lines: ["나"], start: 5.5, end: 6.5),
        ], to: clip, inDocument: data)
        let text = String(decoding: written, as: UTF8.self)
        #expect(text.contains("text-style-def id=\"ts3\""))
        #expect(text.contains("text-style-def id=\"ts4\""))

        let ids = try XMLDocument(data: written).nodes(forXPath: "//text-style-def")
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue }
        #expect(Set(ids).count == ids.count)
    }

    @Test func theLanguageDrivesTheCaptionRole() throws {
        let (data, _, clip) = try fixture()
        let english = FCPXMLWriter(language: "en")
        #expect(english.role == "iTT?captionFormat=ITT.en")
        let written = try english.addingCaptions([Caption(lines: ["hi"], start: 0, end: 1)], to: clip, inDocument: data)
        #expect(try reader.read(data: written).clips.first?.captions.last?.language == "en")
    }

    @Test func writingToAClipThatIsNotThereIsAnError() throws {
        let (data, _, clip) = try fixture()
        var missing = clip
        missing.assetID = "r999"
        #expect(throws: FCPXMLError.clipNotFound(clip.name)) {
            try writer.addingCaptions([Caption(lines: ["가"], start: 0, end: 1)], to: missing, inDocument: data)
        }
    }

    @Test func aDocumentWithNoFrameRateIsAnErrorNotAGuess() throws {
        // No format resource anywhere: refusing beats quietly captioning at some assumed 30fps.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.14">
          <resources><asset id="r2" name="Interview" duration="600s" hasAudio="1"/></resources>
          <asset-clip ref="r2" offset="0s" name="Interview" start="0s" duration="60s"/>
        </fcpxml>
        """
        let data = Data(xml.utf8)
        let clip = try #require(try reader.read(data: data).clips.first)
        #expect(throws: FCPXMLError.self) {
            try writer.addingCaptions([Caption(lines: ["가"], start: 0, end: 1)], to: clip, inDocument: data)
        }
    }

    /// Validated against the DTD Apple ships inside Final Cut Pro — the same grammar FCP imports
    /// against. Skipped where FCP isn't installed (CI), never silently passed.
    @Test(.enabled(if: Fixture.DTD.isAvailable))
    func outputValidatesAgainstApplesOwnDTD() throws {
        let (data, _, clip) = try fixture()
        let written = try writer.addingCaptions([
            Caption(lines: ["안녕하세요"], start: 0, end: 2),
            Caption(lines: ["오늘은 날씨가", "정말 좋네요"], start: 2.5, end: 5),
        ], to: clip, inDocument: data)

        #expect(try Fixture.DTD.validate(written) == nil)
        // …and the fixture itself validates, which is what makes a failure above ours, not Apple's.
        #expect(try Fixture.DTD.validate(data) == nil)
    }
}


/// Lane selection. Captions on one lane may not overlap, and the document we are handed can
/// already carry the editor's own — this is the rule that keeps ours from landing on top.
struct FCPXMLWriterLaneTests {
    let reader = FCPXMLReader()

    private func fixture() throws -> (data: Data, clip: ClipRef) {
        let data = try Fixture.data("caption_one_clip.fcpxml")
        return (data, try #require(try reader.read(data: data).clips.first))
    }

    @Test func capionsAvoidALaneThatIsAlreadyInUse() throws {
        // The fixture's own caption sits on lane 1; ours goes clear of it in time, but still has
        // to move off that lane.
        let (data, clip) = try fixture()
        let written = try FCPXMLWriter().addingCaptions(
            [Caption(lines: ["다른 레인"], start: 4, end: 6)], to: clip, inDocument: data)
        let captions = try #require(try reader.read(data: written).clips.first?.captions)
        #expect(captions.count == 2)
        #expect(captions.last?.lane == 2)
    }

    @Test func aClipWithNoCaptionsGetsLaneOne() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.14">
          <resources>
            <format id="r1" frameDuration="1001/30000s"/>
            <asset id="r2" name="Interview" start="0s" duration="600s" format="r1" hasAudio="1"/>
          </resources>
          <library><event name="E"><project name="P">
            <sequence format="r1" duration="60s" tcStart="0s"><spine>
              <asset-clip ref="r2" offset="0s" name="Interview" start="0s" duration="60s"/>
            </spine></sequence>
          </project></event></library>
        </fcpxml>
        """
        let data = Data(xml.utf8)
        let clip = try #require(try reader.read(data: data).clips.first)
        let written = try FCPXMLWriter().addingCaptions(
            [Caption(lines: ["처음"], start: 0, end: 2)], to: clip, inDocument: data)
        #expect(try reader.read(data: written).clips.first?.captions.first?.lane == 1)
    }

    @Test func everyCaptionInOneRunSharesOneLane() throws {
        let (data, clip) = try fixture()
        let written = try FCPXMLWriter().addingCaptions([
            Caption(lines: ["하나"], start: 4, end: 6),
            Caption(lines: ["둘"], start: 7, end: 9),
            Caption(lines: ["셋"], start: 10, end: 12),
        ], to: clip, inDocument: data)
        let ours = try #require(try reader.read(data: written).clips.first?.captions.dropFirst())
        #expect(Set(ours.map(\.lane)) == [2])
    }

    @Test func anExplicitLaneIsHonoured() throws {
        let (data, clip) = try fixture()
        let written = try FCPXMLWriter(lane: 5).addingCaptions(
            [Caption(lines: ["다섯"], start: 4, end: 6)], to: clip, inDocument: data)
        #expect(try reader.read(data: written).clips.first?.captions.last?.lane == 5)
    }

    // What the lane rule is really for: no two captions on one lane may overlap in time.
    @Test func noTwoCaptionsOnALaneOverlap() throws {
        let (data, clip) = try fixture()
        let written = try FCPXMLWriter().addingCaptions([
            Caption(lines: ["하나"], start: 4, end: 6),
            Caption(lines: ["둘"], start: 6, end: 8),
            Caption(lines: ["셋"], start: 8.5, end: 10),
        ], to: clip, inDocument: data)
        let captions = try #require(try reader.read(data: written).clips.first?.captions)

        for lane in Set(captions.map { $0.lane ?? 0 }) {
            let onLane = captions.filter { ($0.lane ?? 0) == lane }
                .sorted { $0.offset < $1.offset }
            for (earlier, later) in zip(onLane, onLane.dropFirst()) {
                #expect((earlier.offset + earlier.duration) <= later.offset)
            }
        }
    }
}


/// Overlap with the editor's *own* captions.
///
/// Final Cut Pro validates caption overlap per language, not per lane. Importing a document whose
/// new captions overlapped an existing Korean one turned both red in the timeline even though they
/// sat on different lanes — so lane separation is not enough, and these are the rules that came
/// out of that import.
struct FCPXMLWriterExistingCaptionTests {
    let reader = FCPXMLReader()
    let writer = FCPXMLWriter()

    /// The fixture's own caption runs 0s–3.003s on lane 1, in Korean.
    private func fixture() throws -> (data: Data, clip: ClipRef) {
        let data = try Fixture.data("caption_one_clip.fcpxml")
        return (data, try #require(try reader.read(data: data).clips.first))
    }

    private func ours(in document: Data) throws -> [CaptionRef] {
        let captions = try #require(try reader.read(data: document).clips.first?.captions)
        return captions.filter { $0.text != "안녕하세요" }
    }

    @Test func aCaptionCoveredByAnExistingOneIsSkipped() throws {
        let (data, clip) = try fixture()
        let result = try writer.write([Caption(lines: ["숨음"], start: 1, end: 2)], to: clip, inDocument: data)
        #expect(result.written == 0)
        #expect(result.skipped == 1)
        #expect(try ours(in: result.document).isEmpty)
    }

    @Test func aCaptionOverlappingTheEditorsStartIsTrimmed() throws {
        let (data, clip) = try fixture()
        let result = try writer.write([Caption(lines: ["겹침"], start: 2, end: 5)], to: clip, inDocument: data)
        #expect(result.written == 1)
        let written = try #require(try ours(in: result.document).first)
        // Starts where the editor's caption ends (3.003s), not at 2s.
        #expect(written.offset.seconds >= 3.0)
        #expect(abs((written.offset + written.duration).seconds - 5) < 0.05)
    }

    @Test func aCaptionWithTheEditorsInTheMiddleIsSkippedNotSplit() throws {
        // Theirs runs 2s–4s; ours would run 0s–6s straight through it. Splitting ours around it
        // would put the same sentence on screen twice.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.14">
          <resources>
            <format id="r1" frameDuration="1001/30000s"/>
            <asset id="r2" name="Take" start="0s" duration="60s" format="r1" hasAudio="1"/>
          </resources>
          <library><event name="E"><project name="P"><sequence format="r1" duration="60s"><spine>
            <asset-clip ref="r2" offset="0s" name="Take" start="0s" duration="60s">
              <caption lane="1" offset="2s" name="theirs" start="3600s" duration="2s" role="iTT?captionFormat=ITT.ko">
                <text placement="bottom"><text-style ref="ts1">편집자 자막</text-style></text>
                <text-style-def id="ts1"><text-style font=".AppleSystemUIFont" fontSize="13"/></text-style-def>
              </caption>
            </asset-clip>
          </spine></sequence></project></event></library>
        </fcpxml>
        """
        let data = Data(xml.utf8)
        let clip = try #require(try reader.read(data: data).clips.first)
        let result = try writer.write([Caption(lines: ["가운데"], start: 0, end: 6)], to: clip, inDocument: data)
        #expect(result.skipped == 1)
        #expect(result.written == 0)
    }

    @Test func captionsClearOfTheEditorsAreUntouched() throws {
        let (data, clip) = try fixture()
        let result = try writer.write([
            Caption(lines: ["하나"], start: 4, end: 6),
            Caption(lines: ["둘"], start: 7, end: 9),
        ], to: clip, inDocument: data)
        #expect(result.written == 2)
        #expect(result.skipped == 0)
    }

    @Test func aDifferentLanguageDoesNotCollide() throws {
        // English captions are a different role, so Final Cut Pro does not call them an overlap.
        let (data, clip) = try fixture()
        let result = try FCPXMLWriter(language: "en")
            .write([Caption(lines: ["overlaps the Korean one"], start: 1, end: 2)], to: clip, inDocument: data)
        #expect(result.written == 1)
        #expect(result.skipped == 0)
    }

    @Test func nothingTheEditorWroteIsEverChanged() throws {
        let (data, clip) = try fixture()
        let result = try writer.write([Caption(lines: ["겹침"], start: 0, end: 6)], to: clip, inDocument: data)
        let original = try #require(try reader.read(data: result.document).clips.first?.captions
            .first { $0.text == "안녕하세요" })
        #expect(original.offset == .zero)
        #expect(original.duration == FCPTime(180180, 60000))
        #expect(original.lane == 1)
    }
}

/// Where a caption goes inside a clip.
///
/// Apple's DTD orders a clip's children, and `caption` is an anchored item: it must land after the
/// timing and adjust elements and **before** markers, `audio-channel-source`, filters and
/// metadata. The reference export had none of those, so appending worked; a real clip with a
/// Dialogue-1/Dialogue-2 audio configuration does have one, and Final Cut Pro refused the whole
/// import over it.
struct FCPXMLWriterElementOrderTests {
    let reader = FCPXMLReader()
    let writer = FCPXMLWriter()

    /// A clip shaped like the one that failed: every group the DTD puts *after* an anchored item
    /// is present, in the order the DTD wants them.
    private let document = """
    <?xml version="1.0" encoding="UTF-8"?>
    <fcpxml version="1.14">
      <resources>
        <format id="r1" frameDuration="1001/60000s"/>
        <asset id="r2" name="DJI" start="0s" duration="600s" format="r1" hasAudio="1" audioSources="2">
          <media-rep kind="original-media" src="file:///Users/example/Movies/DJI.MP4"/>
        </asset>
        <effect id="r3" name="Loudness" uid="FFAudioLoudness"/>
      </resources>
      <library><event name="E"><project name="P">
        <sequence format="r1" duration="60s" tcStart="0s"><spine>
          <asset-clip ref="r2" offset="0s" name="DJI" start="0s" duration="60s">
            <conform-rate srcFrameRate="60"/>
            <adjust-volume amount="3dB"/>
            <marker start="5s" duration="1001/60000s" value="여기"/>
            <audio-channel-source srcCh="1, 2" role="dialogue"/>
            <filter-audio ref="r3" name="Loudness"/>
            <metadata><md key="com.apple.proapps.studio.cameraISO" value="0"/></metadata>
          </asset-clip>
        </spine></sequence>
      </project></event></library>
    </fcpxml>
    """

    private func written() throws -> XMLElement {
        let data = Data(document.utf8)
        let clip = try #require(try reader.read(data: data).clips.first)
        let output = try writer.addingCaptions([
            Caption(lines: ["하나"], start: 1, end: 3),
            Caption(lines: ["둘"], start: 4, end: 6),
        ], to: clip, inDocument: data)
        let xml = try XMLDocument(data: output)
        return try #require(try xml.nodes(forXPath: "//asset-clip").compactMap { $0 as? XMLElement }.first)
    }

    @Test func captionsLandBeforeTheElementsThatMustFollowThem() throws {
        let names = try written().children?.compactMap { ($0 as? XMLElement)?.name } ?? []
        let lastCaption = try #require(names.lastIndex(of: "caption"))
        for later in ["audio-channel-source", "marker", "filter-audio", "metadata"] {
            let index = try #require(names.firstIndex(of: later), "\(later) missing")
            #expect(lastCaption < index, "caption must precede \(later), got \(names)")
        }
    }

    @Test func captionsLandAfterTheElementsThatMustPrecedeThem() throws {
        let names = try written().children?.compactMap { ($0 as? XMLElement)?.name } ?? []
        let firstCaption = try #require(names.firstIndex(of: "caption"))
        for earlier in ["conform-rate", "adjust-volume"] {
            let index = try #require(names.firstIndex(of: earlier), "\(earlier) missing")
            #expect(index < firstCaption, "\(earlier) must precede caption, got \(names)")
        }
    }

    @Test func capionsKeepTheirOwnOrder() throws {
        let captions = try written().nodes(forXPath: "caption").compactMap { $0 as? XMLElement }
        #expect(captions.count == 2)
        let offsets = try captions.map { try FCPTime.parse($0.attribute(forName: "offset")!.stringValue!) }
        #expect(offsets[0] < offsets[1])
    }

    /// The check that would actually have caught this: Apple's own DTD, on a clip shaped like a
    /// real one rather than like the fixture.
    @Test(.enabled(if: Fixture.DTD.isAvailable))
    func aRichClipStillValidatesAgainstApplesDTD() throws {
        let data = Data(document.utf8)
        let clip = try #require(try reader.read(data: data).clips.first)
        let output = try writer.addingCaptions([Caption(lines: ["가"], start: 1, end: 3)],
                                               to: clip, inDocument: data)
        #expect(try Fixture.DTD.validate(output) == nil)
    }
}

/// Putting a project back inside its own event.
///
/// A project dragged from the browser arrives alone — no library, no event — so importing it makes
/// Final Cut Pro invent an event to hold it, and a copy appears beside the original. The document
/// exported by hand carries both and makes FCP ask about replacing instead.
struct FCPXMLContainerWriterTests {
    private let bareProject = """
    <?xml version="1.0" encoding="UTF-8"?>
    <fcpxml version="1.14">
      <resources><format id="r1" frameDuration="1001/60000s"/></resources>
      <project name="Untitled Project" uid="65AEED54-318B-48D1-938A-CF760EE69037">
        <sequence format="r1" duration="60s" tcStart="0s"><spine/></sequence>
      </project>
    </fcpxml>
    """

    private let container = FCPXMLContainer(
        libraryURL: URL(string: "file:///Users/example/Movies/Untitled.fcpbundle/"),
        eventName: "9-9-26",
        eventUID: "0A9A800C-92D4-4728-A294-3497172F069E"
    )

    @Test func theProjectEndsUpInsideItsEventAndLibrary() throws {
        let wrapped = try FCPXMLContainerWriter.wrapping(Data(bareProject.utf8), in: container)
        let xml = try XMLDocument(data: wrapped)
        let project = try #require(try xml.nodes(forXPath: "/fcpxml/library/event/project")
            .compactMap { $0 as? XMLElement }.first)
        #expect(project.attribute(forName: "name")?.stringValue == "Untitled Project")
        // The uid has to survive, or FCP has nothing to match against.
        #expect(project.attribute(forName: "uid")?.stringValue == "65AEED54-318B-48D1-938A-CF760EE69037")

        let event = try #require(try xml.nodes(forXPath: "/fcpxml/library/event")
            .compactMap { $0 as? XMLElement }.first)
        #expect(event.attribute(forName: "name")?.stringValue == "9-9-26")
        #expect(event.attribute(forName: "uid")?.stringValue == container.eventUID)
        #expect(try xml.nodes(forXPath: "/fcpxml/project").isEmpty)
    }

    @Test func resourcesStayWhereTheyAre() throws {
        let wrapped = try FCPXMLContainerWriter.wrapping(Data(bareProject.utf8), in: container)
        let xml = try XMLDocument(data: wrapped)
        #expect(try xml.nodes(forXPath: "/fcpxml/resources/format").count == 1)
    }

    @Test func aDocumentThatAlreadyHasALibraryIsLeftAlone() throws {
        let data = try Fixture.data("caption_one_clip.fcpxml")
        let wrapped = try FCPXMLContainerWriter.wrapping(data, in: container)
        #expect(wrapped == data)
    }

    @Test func withoutAnEventNameNothingIsChanged() throws {
        let data = Data(bareProject.utf8)
        #expect(try FCPXMLContainerWriter.wrapping(data, in: FCPXMLContainer()) == data)
    }

    @Test(.enabled(if: Fixture.DTD.isAvailable))
    func theWrappedDocumentValidatesAgainstApplesDTD() throws {
        let wrapped = try FCPXMLContainerWriter.wrapping(Data(bareProject.utf8), in: container)
        #expect(try Fixture.DTD.validate(wrapped) == nil)
    }
}

/// Captions, titles, or both.
///
/// Final Cut Pro's caption inspector has no font control; its Subtitle title has every one. The
/// two are different objects — a caption is a subtitle track, a title is text in the picture — and
/// they sit on one timeline together, so all three answers are real.
struct FCPXMLWriterFormTests {
    let reader = FCPXMLReader()

    private func write(_ form: FCPXMLWriter.Form) throws -> (document: Data, xml: XMLDocument) {
        let data = try Fixture.withoutCaptions("caption_one_clip.fcpxml")
        let clip = try #require(try reader.read(data: data).clips.first)
        let written = try FCPXMLWriter(form: form).addingCaptions([
            Caption(lines: ["첫 줄", "둘째 줄"], start: 1, end: 3),
            Caption(lines: ["다음"], start: 4, end: 6),
        ], to: clip, inDocument: data)
        return (written, try XMLDocument(data: written))
    }

    private func count(_ xml: XMLDocument, _ name: String) throws -> Int {
        try xml.nodes(forXPath: "//\(name)").count
    }

    @Test func captionsOnly() throws {
        let (_, xml) = try write(.caption)
        #expect(try count(xml, "caption") == 2)
        #expect(try count(xml, "title") == 0)
        // No effect resource is added for a document that will not use one.
        #expect(try count(xml, "effect") == 0)
    }

    @Test func titlesOnly() throws {
        let (_, xml) = try write(.title)
        #expect(try count(xml, "title") == 2)
        #expect(try count(xml, "caption") == 0)
    }

    @Test func bothLandOnDifferentLanes() throws {
        let (_, xml) = try write(.both)
        #expect(try count(xml, "caption") == 2)
        #expect(try count(xml, "title") == 2)

        let captionLanes = try xml.nodes(forXPath: "//caption")
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "lane")?.stringValue }
        let titleLanes = try xml.nodes(forXPath: "//title")
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "lane")?.stringValue }
        // Sharing a lane would stack them on top of each other.
        #expect(Set(captionLanes).isDisjoint(with: Set(titleLanes)))
    }

    @Test func theTitleReferencesFinalCutProsOwnSubtitleTemplate() throws {
        let (_, xml) = try write(.title)
        let effect = try #require(try xml.nodes(forXPath: "//effect").compactMap { $0 as? XMLElement }.first)
        // The leading "..." is literal — this is exactly what Final Cut Pro exported.
        #expect(effect.attribute(forName: "uid")?.stringValue
            == ".../Titles.localized/Subtitles.localized/Subtitle.localized/Subtitle.moti")
        #expect(effect.attribute(forName: "name")?.stringValue == "Subtitle")

        let title = try #require(try xml.nodes(forXPath: "//title").compactMap { $0 as? XMLElement }.first)
        #expect(title.attribute(forName: "ref")?.stringValue == effect.attribute(forName: "id")?.stringValue)
    }

    @Test func oneEffectResourceIsSharedByEveryTitle() throws {
        let (_, xml) = try write(.title)
        #expect(try count(xml, "effect") == 1)
    }

    @Test func aResourceIdIsNotReused() throws {
        let (_, xml) = try write(.title)
        let ids = try xml.nodes(forXPath: "/fcpxml/resources/*")
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue }
        #expect(Set(ids).count == ids.count)
    }

    /// Titles are on their own type scale: FCP's Subtitle writes 100 where a caption writes 13.
    @Test func aTitleUsesTheTitleTypeScale() throws {
        let (_, xml) = try write(.title)
        let style = try #require(try xml.nodes(forXPath: "//title/text-style-def/text-style")
            .compactMap { $0 as? XMLElement }.first)
        #expect(style.attribute(forName: "fontSize")?.stringValue == "100")
        #expect(style.attribute(forName: "font")?.stringValue == "Helvetica Neue")
    }

    @Test func styleScalesAcrossBothForms() {
        let style = CaptionStyle(fontSize: 26)
        #expect(style.fontSize == 26)          // caption points
        #expect(style.titleFontSize == 200)    // the same size on the title scale
    }

    @Test(.enabled(if: Fixture.DTD.isAvailable))
    func everyFormValidatesAgainstApplesDTD() throws {
        for form in FCPXMLWriter.Form.allCases {
            let (document, _) = try write(form)
            #expect(try Fixture.DTD.validate(document) == nil, "\(form) did not validate")
        }
    }
}

/// Which frame grid each anchored item is measured against.
///
/// A clip conforming 60p into a 59.94 timeline has two grids, and Final Cut Pro does not use the
/// same one for both kinds of item: its own Subtitle title sits at `31/20s` — 93 frames at 60, and
/// not a whole frame at 59.94 — while its own caption sits at `180180/60000s`, a whole frame at
/// 59.94 and not at 60. Using the sequence grid for titles earns "The item is not on an edit frame
/// boundary" from the importer, once per title.
struct FCPXMLWriterFrameGridTests {
    let reader = FCPXMLReader()

    /// The reference export's clip: 60p asset, 59.94 sequence.
    private func conformedClip() throws -> (data: Data, clip: ClipRef) {
        let data = try Fixture.withoutCaptions("caption_one_clip.fcpxml")
        let clip = try #require(try reader.read(data: data).clips.first)
        #expect(clip.assetFrameDuration == FCPTime(10, 600))       // 60
        #expect(try reader.read(data: data).frameDuration == FCPTime(1001, 60000))  // 59.94
        return (data, clip)
    }

    private func times(_ xml: XMLDocument, _ element: String) throws -> [FCPTime] {
        try xml.nodes(forXPath: "//\(element)")
            .compactMap { $0 as? XMLElement }
            .flatMap { node -> [FCPTime] in
                ["offset", "duration"].compactMap { name in
                    (node.attribute(forName: name)?.stringValue).flatMap { try? FCPTime.parse($0) }
                }
            }
    }

    /// The reference export is the specification here: `offset="31/20s"` is a whole frame only at
    /// the clip's 60, and `duration="300300/60000s"` only at the sequence's 59.94.
    @Test func titleOffsetsUseTheClipGridAndDurationsTheSequenceGrid() throws {
        let (data, clip) = try conformedClip()
        let written = try FCPXMLWriter(form: .title).addingCaptions([
            Caption(lines: ["하나"], start: 1.02, end: 3.04),
            Caption(lines: ["둘"], start: 4.55, end: 6.1),
        ], to: clip, inDocument: data)
        let xml = try XMLDocument(data: written)

        let clipGrid = FCPTime(10, 600)
        let sequenceGrid = FCPTime(1001, 60000)
        func wholeFrames(_ time: FCPTime, on grid: FCPTime) -> Bool {
            let frames = Double(time.numerator * grid.denominator) / Double(time.denominator * grid.numerator)
            return abs(frames - frames.rounded()) < 0.0001
        }

        for title in try xml.nodes(forXPath: "//title").compactMap({ $0 as? XMLElement }) {
            let offset = try FCPTime.parse(#require(title.attribute(forName: "offset")?.stringValue))
            let duration = try FCPTime.parse(#require(title.attribute(forName: "duration")?.stringValue))
            let start = try FCPTime.parse(#require(title.attribute(forName: "start")?.stringValue))
            #expect(wholeFrames(offset, on: clipGrid), "offset \(offset) is not a whole clip frame")
            #expect(wholeFrames(duration, on: sequenceGrid), "duration \(duration) is not a whole sequence frame")
            #expect(wholeFrames(start, on: sequenceGrid), "start \(start) is not a whole sequence frame")
        }
    }

    @Test func titleOffsetsLandOnTheClipsOwnGrid() throws {
        let (data, clip) = try conformedClip()
        let written = try FCPXMLWriter(form: .title).addingCaptions([
            Caption(lines: ["하나"], start: 1.02, end: 3.04),
            Caption(lines: ["둘"], start: 4.55, end: 6.1),
        ], to: clip, inDocument: data)
        let xml = try XMLDocument(data: written)

        let clipGrid = FCPTime(10, 600)
        for title in try xml.nodes(forXPath: "//title").compactMap({ $0 as? XMLElement }) {
            let offset = try FCPTime.parse(#require(title.attribute(forName: "offset")?.stringValue))
            let frames = Double(offset.numerator * clipGrid.denominator)
                / Double(offset.denominator * clipGrid.numerator)
            #expect(abs(frames - frames.rounded()) < 0.0001,
                    "\(offset) is not a whole frame at the clip's rate")
        }
    }

    @Test func captionsStayOnTheSequenceGrid() throws {
        let (data, clip) = try conformedClip()
        let written = try FCPXMLWriter(form: .caption).addingCaptions([
            Caption(lines: ["하나"], start: 1.02, end: 3.04),
        ], to: clip, inDocument: data)
        let xml = try XMLDocument(data: written)

        let sequenceGrid = FCPTime(1001, 60000)
        for time in try times(xml, "caption") {
            let frames = Double(time.numerator * sequenceGrid.denominator)
                / Double(time.denominator * sequenceGrid.numerator)
            #expect(abs(frames - frames.rounded()) < 0.0001,
                    "\(time) is not a whole frame at the sequence rate")
        }
    }

    /// Both kinds together, each on its own grid.
    @Test func bothFormsUseTheirOwnGrid() throws {
        let (data, clip) = try conformedClip()
        let written = try FCPXMLWriter(form: .both).addingCaptions([
            Caption(lines: ["하나"], start: 1.02, end: 3.04),
        ], to: clip, inDocument: data)
        let xml = try XMLDocument(data: written)
        #expect(try xml.nodes(forXPath: "//caption").count == 1)
        #expect(try xml.nodes(forXPath: "//title").count == 1)

        let clipGrid = FCPTime(10, 600)
        for title in try xml.nodes(forXPath: "//title").compactMap({ $0 as? XMLElement }) {
            let offset = try FCPTime.parse(#require(title.attribute(forName: "offset")?.stringValue))
            let frames = Double(offset.numerator * clipGrid.denominator)
                / Double(offset.denominator * clipGrid.numerator)
            #expect(abs(frames - frames.rounded()) < 0.0001)
        }
    }

    /// When the two rates are the same there is only one grid and nothing to choose.
    @Test func anUnconformedClipHasOneGrid() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.14">
          <resources>
            <format id="r1" frameDuration="1001/30000s"/>
            <asset id="r2" name="Take" start="0s" duration="60s" format="r1" hasAudio="1"/>
          </resources>
          <library><event name="E"><project name="P"><sequence format="r1" duration="60s"><spine>
            <asset-clip ref="r2" offset="0s" name="Take" start="0s" duration="60s"/>
          </spine></sequence></project></event></library>
        </fcpxml>
        """
        let data = Data(xml.utf8)
        let clip = try #require(try reader.read(data: data).clips.first)
        let written = try FCPXMLWriter(form: .both).addingCaptions(
            [Caption(lines: ["가"], start: 1, end: 2)], to: clip, inDocument: data)
        let document = try XMLDocument(data: written)
        let grid = FCPTime(1001, 30000)
        for element in ["caption", "title"] {
            for time in try times(document, element) {
                let frames = Double(time.numerator * grid.denominator)
                    / Double(time.denominator * grid.numerator)
                #expect(abs(frames - frames.rounded()) < 0.0001)
            }
        }
    }
}
