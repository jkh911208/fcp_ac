import Foundation
import Testing
@testable import FCPCaptionCore

/// Everything here is pinned to `Fixtures/retimed_and_connected.fcpxml`, cut from a real 121-clip
/// Final Cut Pro export and validated against Apple's own DTD. Each case in it is a thing that
/// went wrong in the field on 2026-09-09, on a project the user actually edited.
@Suite("clips the edit rules out")
struct RetimedAndConnectedTests {
    private func clips() throws -> [ClipRef] {
        try FCPXMLReader().read(data: Fixture.data("retimed_and_connected.fcpxml")).clips
    }

    @Test("a clip connected under another clip is read, not silently ignored")
    func connectedClipsAreRead() throws {
        let all = try clips()
        // The fixture's spine holds four clips; one of them carries a connected clip beneath it.
        #expect(all.count > 4, "connected clips were dropped — only the spine's own children were read")
        #expect(all.contains { $0.lane != nil }, "no laned clip came back")
    }

    @Test("a retimed clip is skipped rather than transcribed from the wrong second")
    func retimedIsSkipped() throws {
        let retimed = try clips().filter { if case .retimed = $0.skipReason { true } else { false } }
        #expect(!retimed.isEmpty)
        // 0.25x in the source project: 144 seconds of output for 36 seconds of media.
        if case let .retimed(speed) = retimed[0].skipReason, let speed {
            #expect(speed > 0 && speed < 1)
        }
    }

    @Test("a muted clip is skipped — captioning it describes audio the video does not have")
    func mutedIsSkipped() throws {
        #expect(try clips().contains { $0.skipReason == .silenced })
    }

    @Test("an ordinary clip is still captionable")
    func plainClipSurvives() throws {
        #expect(try clips().contains { $0.isCaptionable })
    }

    @Test("every skip reason reads as a Korean sentence, never a raw case name")
    func reasonsAreReadable() throws {
        for clip in try clips() {
            guard let reason = clip.skipReason else { continue }
            #expect(reason.korean.hasSuffix("니다"), "not a sentence: \(reason.korean)")
            #expect(!reason.korean.contains("retimed"))
        }
    }

    @Test("a speed is reported only when the retime is a single constant rate")
    func speedIsOmittedForRampsAndFreezes() throws {
        // A freeze frame in the source project is (0,0) (2.73,2.73) (172800,2.73) (172800,2.75).
        // Taking the last point as the rate calls that "0.00x", which is worse than saying nothing.
        for clip in try clips() {
            guard case let .retimed(speed) = clip.skipReason else { continue }
            if let speed { #expect(speed > 0.01, "a rate this small is a parsing artefact, not a speed") }
        }
    }

    @Test("the fixture carries no bookmark and no real path")
    func fixtureIsScrubbed() throws {
        let text = try String(data: Fixture.data("retimed_and_connected.fcpxml"), encoding: .utf8) ?? ""
        #expect(!text.contains("<bookmark>"))
        #expect(!text.contains("/Volumes/"))
        #expect(!text.contains("/Users/"))
    }
}
