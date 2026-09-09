import Foundation
import Testing
@testable import FCPCaptionCore

struct FCPXMLWriterTests {
    let reader = FCPXMLReader()
    let writer = FCPXMLWriter()

    private func fixture() throws -> (data: Data, document: FCPXMLDocument, clip: ClipRef) {
        let data = try Fixture.data("caption_one_clip.fcpxml")
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

        #expect(clip.captions.count == 3)   // the fixture's own caption is left alone
        let ours = clip.captions.filter { $0.text != "안녕하세요" || $0.duration != FCPTime(180180, 60000) }
        #expect(ours.count == 2)

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
        #expect(clip.captions.count == 2)   // the fixture's + the one that fits
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
        let (data, _, clip) = try fixture()   // the fixture already defines ts1 and ts2
        let written = try writer.addingCaptions([
            Caption(lines: ["가"], start: 0, end: 1),
            Caption(lines: ["나"], start: 1.5, end: 2.5),
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
        // The fixture's own caption sits on lane 1 from 0s, exactly where ours would go.
        let (data, clip) = try fixture()
        let written = try FCPXMLWriter().addingCaptions(
            [Caption(lines: ["겹침"], start: 0, end: 2)], to: clip, inDocument: data)
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
            Caption(lines: ["하나"], start: 0, end: 2),
            Caption(lines: ["둘"], start: 3, end: 5),
            Caption(lines: ["셋"], start: 6, end: 8),
        ], to: clip, inDocument: data)
        let ours = try #require(try reader.read(data: written).clips.first?.captions.dropFirst())
        #expect(Set(ours.map(\.lane)) == [2])
    }

    @Test func anExplicitLaneIsHonoured() throws {
        let (data, clip) = try fixture()
        let written = try FCPXMLWriter(lane: 5).addingCaptions(
            [Caption(lines: ["다섯"], start: 0, end: 2)], to: clip, inDocument: data)
        #expect(try reader.read(data: written).clips.first?.captions.last?.lane == 5)
    }

    // What the lane rule is really for: no two captions on one lane may overlap in time.
    @Test func noTwoCaptionsOnALaneOverlap() throws {
        let (data, clip) = try fixture()
        let written = try FCPXMLWriter().addingCaptions([
            Caption(lines: ["하나"], start: 0, end: 2),
            Caption(lines: ["둘"], start: 2, end: 4),
            Caption(lines: ["셋"], start: 4.5, end: 6),
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
