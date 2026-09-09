import Foundation
import Testing
@testable import FCPCaptionCore

/// Everything asserted here was read off a real Final Cut Pro 12.3 export
/// (`Fixtures/caption_one_clip.fcpxml`), which is the only authority on this schema.
struct FCPXMLReaderTests {
    let reader = FCPXMLReader()

    private func document() throws -> FCPXMLDocument {
        try reader.read(data: try Fixture.data("caption_one_clip.fcpxml"))
    }

    @Test func readsTheDocumentVersion() throws {
        #expect(try document().version == "1.14")
    }

    @Test func readsTheSequence() throws {
        let sequence = try #require(try document().sequence)
        #expect(sequence.projectName == "Untitled Project")
        #expect(sequence.eventName == "9-9-26")
        #expect(sequence.formatID == "r1")
        #expect(sequence.frameDuration == FCPTime(1001, 60000))   // 59.94
        #expect(sequence.duration == FCPTime(1472471, 60000))
        #expect(sequence.tcStart == .zero)
    }

    @Test func readsTheClip() throws {
        let document = try document()
        #expect(document.clips.count == 1)
        let clip = try #require(document.clips.first)
        #expect(clip.element == "asset-clip")
        #expect(clip.assetID == "r2")
        #expect(clip.name == "IMG_2194")
        #expect(clip.offset == .zero)
        #expect(clip.start == .zero)
        #expect(clip.duration == FCPTime(1472471, 60000))
        #expect(clip.hasAudio)
        #expect(clip.mediaURL?.lastPathComponent == "IMG_2194.MOV")
        // The asset's own format is 60p; the sequence it sits in is 59.94. Captions follow the
        // sequence, so both have to survive the read.
        #expect(clip.assetFrameDuration == FCPTime(10, 600))
        #expect(document.frameDuration == FCPTime(1001, 60000))
    }

    @Test func readsTheCaption() throws {
        let clip = try #require(try document().clips.first)
        #expect(clip.captions.count == 1)
        let caption = try #require(clip.captions.first)
        #expect(caption.role == "iTT?captionFormat=ITT.ko")
        #expect(caption.language == "ko")
        #expect(caption.lane == 1)
        #expect(caption.offset == .zero)
        #expect(caption.start == FCPTime(215999784, 60000))
        #expect(caption.duration == FCPTime(180180, 60000))
        // Two runs in the file — the text and the line break FCP puts in a run of its own.
        #expect(caption.text == "안녕하세요")
    }

    @Test func rejectsWhatIsNotFCPXML() {
        #expect(throws: FCPXMLError.notXML) { try FCPXMLReader().read(data: Data("not xml".utf8)) }
        #expect(throws: FCPXMLError.notFCPXML) {
            try FCPXMLReader().read(data: Data("<?xml version=\"1.0\"?><other/>".utf8))
        }
    }

    @Test func reportsWhichAttributeWasMissing() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.14">
          <resources><asset id="r2" name="clip"/></resources>
          <library><event><project><sequence format="r1"><spine>
            <asset-clip ref="r2" offset="0s" name="clip"/>
          </spine></sequence></project></event></library>
        </fcpxml>
        """
        // The sequence names format r1, which this document never declares — that is an error,
        // not something to paper over with a default frame rate.
        #expect(throws: FCPXMLError.unknownResource("r1")) {
            try FCPXMLReader().read(data: Data(xml.utf8))
        }
    }

    @Test func readsAClipWithNoProjectAroundIt() throws {
        // What a drop onto the panel may look like: resources and a clip, no library/project.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.13">
          <resources>
            <format id="r1" frameDuration="1001/30000s" width="1920" height="1080"/>
            <asset id="r2" name="Interview" start="0s" duration="600s" hasVideo="1" format="r1" hasAudio="1">
              <media-rep kind="original-media" src="file:///Users/example/Movies/Interview.mov"/>
            </asset>
          </resources>
          <asset-clip ref="r2" offset="0s" name="Interview" start="10s" duration="60s"/>
        </fcpxml>
        """
        let document = try FCPXMLReader().read(data: Data(xml.utf8))
        #expect(document.version == "1.13")
        #expect(document.sequence == nil)
        #expect(document.clips.count == 1)
        #expect(document.clips[0].start == FCPTime(10))
        #expect(document.frameDuration == FCPTime(1001, 30000))   // falls back to the asset's format
    }

    @Test func clipStartDefaultsToTheAssetStartNotZero() throws {
        // A clip with no start attribute plays from the asset's start; assuming 0 would shift
        // every caption by the media's own offset.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.14">
          <resources>
            <format id="r1" frameDuration="1001/30000s"/>
            <asset id="r2" name="Interview" start="3600s" duration="600s" format="r1" hasAudio="1"/>
          </resources>
          <asset-clip ref="r2" offset="0s" name="Interview" duration="60s"/>
        </fcpxml>
        """
        let document = try FCPXMLReader().read(data: Data(xml.utf8))
        #expect(document.clips[0].start == FCPTime(3600))
    }
}
