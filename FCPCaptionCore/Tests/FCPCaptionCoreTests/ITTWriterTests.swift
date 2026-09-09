import Foundation
import Testing
@testable import FCPCaptionCore

/// Checked against `Fixtures/caption_korean.itt`, a real Final Cut Pro export. The point of this
/// format is the one thing SubRip cannot do: say which language the captions are in.
struct ITTWriterTests {
    /// The fixture's sequence: 3840x2160p5994.
    let frame = FCPTime(1001, 60000)

    private func fixture() throws -> String {
        String(decoding: try Fixture.data("caption_korean.itt"), as: UTF8.self)
    }

    @Test func theLanguageIsOnTheRoot() throws {
        let itt = ITTWriter(language: "ko").string(from: [Caption(lines: ["안녕하세요"], start: 0, end: 3.003)],
                                                   frameDuration: frame)
        #expect(itt.contains("xml:lang=\"ko\""))
        #expect(try fixture().contains("xml:lang=\"ko\""))   // and that is where FCP puts it
    }

    @Test func aDifferentLanguageIsCarriedThrough() {
        let itt = ITTWriter(language: "en").string(from: [Caption(lines: ["hello"], start: 0, end: 1)],
                                                   frameDuration: frame)
        #expect(itt.contains("xml:lang=\"en\""))
    }

    // The fixture's only caption runs 0s to 3.003s and Final Cut Pro wrote it as
    // begin="00:00:00:00" end="00:00:03:00" — timecode counted in *nominal* 60fps frames.
    @Test func timesMatchTheFixtureExactly() throws {
        let itt = ITTWriter().string(from: [Caption(lines: ["안녕하세요"], start: 0, end: 3.003)],
                                     frameDuration: frame)
        #expect(itt.contains("begin=\"00:00:00:00\""))
        #expect(itt.contains("end=\"00:00:03:00\""))
        #expect(try fixture().contains("end=\"00:00:03:00\""))
    }

    @Test func theFrameRateIsNominalWithThePulldownMultiplier() throws {
        let itt = ITTWriter().string(from: [], frameDuration: frame)
        // 59.94 is written as 60 with a 1000/1001 multiplier, exactly as FCP writes it.
        #expect(itt.contains("ttp:frameRate=\"60\""))
        #expect(itt.contains("ttp:frameRateMultiplier=\"1000 1001\""))
        #expect(try fixture().contains("ttp:frameRateMultiplier=\"1000 1001\""))
    }

    @Test func wholeNumberRatesGetNoPulldown() {
        let itt = ITTWriter().string(from: [], frameDuration: FCPTime(1, 25))
        #expect(itt.contains("ttp:frameRate=\"25\""))
        #expect(itt.contains("ttp:frameRateMultiplier=\"1 1\""))
    }

    @Test func timecodeCountsInNominalFrames() {
        let rate = TimecodeRate(frameDuration: FCPTime(1001, 60000))
        #expect(rate.nominal == 60)
        #expect(rate.timecode(0) == "00:00:00:00")
        #expect(rate.timecode(3.003) == "00:00:03:00")
        // An hour of 59.94 material is 3600 * 1000/1001 timecode hours' worth of real seconds;
        // counting real frames instead of nominal ones is what drifts.
        #expect(rate.timecode(60.06) == "00:01:00:00")
        // One real second is 59.94 frames, which rounds to 60 — a whole timecode second. That
        // 0.1% gap between wall clock and timecode is exactly what non-drop frame means.
        #expect(rate.timecode(1.0) == "00:00:01:00")
    }

    @Test func twentyFourFpsCountsAsYouWouldExpect() {
        let rate = TimecodeRate(frameDuration: FCPTime(1, 24))
        #expect(rate.timecode(1) == "00:00:01:00")
        #expect(rate.timecode(1.5) == "00:00:01:12")
        #expect(rate.timecode(3661) == "01:01:01:00")
    }

    @Test func twoLinesBecomeOneBreak() {
        let itt = ITTWriter().string(from: [Caption(lines: ["오늘은 날씨가", "정말 좋네요"], start: 0, end: 2)],
                                     frameDuration: frame)
        #expect(itt.contains(">오늘은 날씨가<br/>정말 좋네요</p>"))
    }

    /// A caption written by this project ends with its last line, not with a line break.
    ///
    /// The reference export ends `안녕하세요<br/>` because the editor had typed a newline into that
    /// caption. Copying the trailing break added an empty third line to every caption, which is
    /// one more than Final Cut Pro allows — and it draws those captions in red.
    @Test func thereIsNoTrailingLineBreak() {
        let itt = ITTWriter().string(from: [
            Caption(lines: ["한 줄"], start: 0, end: 2),
            Caption(lines: ["첫 줄", "둘째 줄"], start: 3, end: 5),
        ], frameDuration: frame)
        #expect(!itt.contains("<br/></p>"))
        #expect(itt.contains(">한 줄</p>"))
    }

    @Test func noCaptionExceedsTwoRenderedLines() throws {
        let itt = ITTWriter().string(from: [Caption(lines: ["첫 줄", "둘째 줄"], start: 0, end: 2)],
                                     frameDuration: frame)
        let document = try XMLDocument(data: Data(itt.utf8))
        for paragraph in try document.nodes(forXPath: "//*[local-name()='p']") {
            let breaks = try paragraph.nodes(forXPath: ".//*[local-name()='br']").count
            #expect(breaks <= 1, "a caption may hold at most two lines, so at most one break")
        }
    }

    @Test func theStructureMatchesWhatFinalCutWrites() throws {
        let itt = ITTWriter().string(from: [Caption(lines: ["가"], start: 0, end: 1)], frameDuration: frame)
        for marker in ["ttp:timeBase=\"smpte\"", "ttp:dropMode=\"nonDrop\"",
                       "<style xml:id=\"normal\"", "<region xml:id=\"bottom\"",
                       "tts:origin=\"0% 85%\"", "region=\"bottom\""] {
            #expect(itt.contains(marker), "missing \(marker)")
            #expect(try fixture().contains(marker), "fixture lacks \(marker)")
        }
    }

    @Test func dropFrameIsWrittenWhenTheSequenceUsesIt() {
        let itt = ITTWriter().string(from: [], frameDuration: FCPTime(1001, 30000), dropFrame: true)
        #expect(itt.contains("ttp:dropMode=\"dropNTSC\""))
    }

    @Test func theOutputIsWellFormedXML() throws {
        let itt = ITTWriter().string(from: [
            Caption(lines: ["첫 줄", "둘째 줄"], start: 0, end: 2),
            Caption(lines: ["다음"], start: 2.5, end: 4),
        ], frameDuration: frame)
        let document = try XMLDocument(data: Data(itt.utf8))
        let paragraphs = try document.nodes(forXPath: "//*[local-name()='p']")
        #expect(paragraphs.count == 2)
        #expect(document.rootElement()?.name == "tt")
    }

    @Test func noCaptionsStillProducesAValidDocument() throws {
        let itt = ITTWriter().string(from: [], frameDuration: frame)
        #expect(throws: Never.self) { try XMLDocument(data: Data(itt.utf8)) }
    }
}
