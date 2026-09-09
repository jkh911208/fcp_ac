import Foundation
import Testing
@testable import FCPCaptionCore

struct SRTWriterTests {
    @Test func writesSubRipBlocks() {
        let srt = SRTWriter.string(from: [
            Caption(lines: ["안녕하세요"], start: 0, end: 1.5),
            Caption(lines: ["오늘은 날씨가", "정말 좋네요"], start: 1.5, end: 4.25),
        ])
        #expect(srt == """
        1
        00:00:00,000 --> 00:00:01,500
        안녕하세요

        2
        00:00:01,500 --> 00:00:04,250
        오늘은 날씨가
        정말 좋네요


        """)
    }

    @Test func timecodesCarryHoursAndClampNegatives() {
        #expect(SRTWriter.timecode(3661.007) == "01:01:01,007")
        #expect(SRTWriter.timecode(-1) == "00:00:00,000")
    }

    @Test func emptyInputWritesNothing() {
        #expect(SRTWriter.string(from: []).isEmpty)
    }
}
