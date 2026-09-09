import Foundation
import Testing
@testable import FCPCaptionCore

/// The numbers here are taken from `Fixtures/caption_one_clip.fcpxml`, so the arithmetic is
/// checked against what Final Cut Pro actually wrote rather than against a made-up frame rate.
struct FCPTimeTests {
    /// 3840x2160p5994 — the reference export's sequence format.
    let frame = FCPTime(1001, 60000)

    @Test func parsesBothFormsFinalCutWrites() throws {
        #expect(try FCPTime.parse("0s") == FCPTime.zero)
        #expect(try FCPTime.parse("1001/60000s") == FCPTime(1001, 60000))
        #expect(try FCPTime.parse("14710/600s") == FCPTime(14710, 600))
        #expect(try FCPTime.parse(" 5s ") == FCPTime(5))
        #expect(try FCPTime.parse("5") == FCPTime(5))   // no trailing s, seen on some attributes
    }

    @Test func rejectsGarbage() {
        #expect(throws: FCPXMLError.self) { try FCPTime.parse("abc") }
        #expect(throws: FCPXMLError.self) { try FCPTime.parse("1/0s") }
        #expect(throws: FCPXMLError.self) { try FCPTime.parse("s") }
    }

    @Test func printsTheWayFinalCutDoes() {
        #expect(FCPTime.zero.description == "0s")
        #expect(FCPTime(180180, 60000).description == "180180/60000s")
        #expect(FCPTime(5).description == "5s")
        // Unreduced on purpose: FCP writes 180180/60000s, and round-tripping must not rewrite it.
        #expect(FCPTime(180180, 60000).reduced().description == "3003/1000s")
    }

    @Test func comparesByValueNotRepresentation() {
        #expect(FCPTime(180180, 60000) == FCPTime(3003, 1000))
        #expect(FCPTime(1, 2) < FCPTime(2, 3))
        #expect(Set([FCPTime(180180, 60000), FCPTime(3003, 1000)]).count == 1)
    }

    @Test func addsAndSubtracts() {
        #expect(FCPTime(1, 2) + FCPTime(1, 3) == FCPTime(5, 6))
        #expect(FCPTime(1, 2) - FCPTime(1, 3) == FCPTime(1, 6))
        #expect((FCPTime(5) - FCPTime(5)) == FCPTime.zero)
    }

    // The fixture's caption: start 215999784/60000s, duration 180180/60000s.
    @Test func fixtureCaptionTimesAreWholeFrames() throws {
        let start = try FCPTime.parse("215999784/60000s")
        let duration = try FCPTime.parse("180180/60000s")
        #expect(start.frameCount(at: frame) == 215784)
        #expect(duration.frameCount(at: frame) == 180)
        #expect(start.aligned(to: frame, rounding: .nearest) == start)
        // ~1 hour, but not exactly: 59.94 fps has no frame boundary at 3600s.
        #expect(abs(start.seconds - 3600) < 0.01)
    }

    @Test func alignmentRoundsTheWayThePolicySays() {
        // 1.5 frames past zero.
        let oneAndAHalfFrames = FCPTime(1001 * 3, 60000 * 2)
        #expect(oneAndAHalfFrames.aligned(to: frame, rounding: .down) == FCPTime(1001, 60000))
        #expect(oneAndAHalfFrames.aligned(to: frame, rounding: .up) == FCPTime(2002, 60000))
        #expect(oneAndAHalfFrames.aligned(to: frame, rounding: .nearest) == FCPTime(2002, 60000))
    }

    @Test func alignedValuesKeepTheFrameDenominator() {
        // Printing 180180/60000s rather than 3003/1000s is what makes our output look like FCP's.
        let aligned = FCPTime.seconds(3.003, alignedTo: frame, rounding: .nearest)
        #expect(aligned.description == "180180/60000s")
        #expect(aligned.denominator == 60000)
    }

    @Test func secondsSnapToTheGrid() {
        // 24 fps, to keep the arithmetic checkable by eye.
        let film = FCPTime(1, 24)
        #expect(FCPTime.seconds(1.0, alignedTo: film, rounding: .nearest) == FCPTime(24, 24))
        #expect(FCPTime.seconds(1.03, alignedTo: film, rounding: .down) == FCPTime(24, 24))
        #expect(FCPTime.seconds(1.03, alignedTo: film, rounding: .up) == FCPTime(25, 24))
        #expect(FCPTime.seconds(0, alignedTo: film) == FCPTime.zero)
    }

    @Test func negativeDenominatorIsNormalized() {
        let time = FCPTime(1, -2)
        #expect(time.denominator > 0)
        #expect(time.seconds == -0.5)
    }
}
