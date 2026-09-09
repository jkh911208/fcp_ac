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
        // FCP never writes a decimal, but other FCPXML producers do; reading one is free.
        #expect(try FCPTime.parse("2.5s") == FCPTime(5, 2))
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

/// The local model list. These identifiers are folder names in a Hugging Face repository, so a
/// typo is a download that 404s at the worst moment — on a user's first run.
struct WhisperModelTests {
    @Test func exactlyTwoModelsAreOffered() {
        #expect(WhisperModel.allCases.map(\.displayName) == ["large-v3", "large-v3-turbo"])
    }

    @Test func accuracyIsTheDefaultAndTurboIsTheSmallerDownload() {
        // large-v3 by default: this app exists because the built-in transcription gets Korean
        // wrong, so accuracy is what it is for. Turbo is the deliberate trade.
        #expect(WhisperModel.default == .largeV3)
        #expect(WhisperModel.largeV3Turbo.downloadSizeMB < WhisperModel.largeV3.downloadSizeMB)
    }

    @Test func everyModelExplainsItselfAndItsCost() {
        for model in WhisperModel.allCases {
            #expect(!model.summary.isEmpty)
            #expect(model.downloadSizeDescription.hasSuffix(" GB"))
        }
        #expect(WhisperModel.largeV3.downloadSizeDescription == "3.0 GB")
        #expect(WhisperModel.largeV3Turbo.downloadSizeDescription == "1.5 GB")
    }

    @Test func identifiersAreTheMacOptimisedVariants() {
        // The `_turbo` folder suffix is WhisperKit's macOS compute optimisation of the same
        // weights, not a different model — both entries want it.
        #expect(WhisperModel.largeV3.identifier == "openai_whisper-large-v3_turbo")
        #expect(WhisperModel.largeV3Turbo.identifier == "openai_whisper-large-v3-v20240930_turbo")
        #expect(WhisperModel.allCases.allSatisfy { $0.identifier.hasSuffix("_turbo") })
    }

    @Test func modelsLiveInApplicationSupport() {
        // percentEncoded: false — the path has a space in it, and the encoded form is not a path.
        #expect(WhisperModel.defaultDirectory.path(percentEncoded: false)
            .hasSuffix("Application Support/FCPCaption/models/"))
    }
}

/// Decoding options. The numbers behind these defaults are measured, and recorded on `Options`.
struct WhisperKitEngineOptionsTests {
    @Test func theDefaultRecoversRatherThanRepeats() {
        // Turning the retries off makes a run byte-identical — and loses a third of the speech on
        // the clip it was measured against. Completeness wins by default.
        #expect(WhisperKitEngine.Options.complete.temperatureFallbackCount == 5)
        #expect(!WhisperKitEngine.Options.complete.isReproducible)
        #expect(WhisperKitEngine.Options().temperatureFallbackCount == 5)
    }

    @Test func theReproducibleOptionTurnsOffOnlyTheRetries() {
        let options = WhisperKitEngine.Options.reproducible
        #expect(options.isReproducible)
        // Fewer workers neither helped reproducibility nor speed, so they stay at the default.
        #expect(options.concurrentWorkerCount == 16)
    }

    @Test func bothOptionsExplainTheirTradeoff() {
        #expect(WhisperKitEngine.Options.complete.summary.contains("달라집니다"))
        #expect(WhisperKitEngine.Options.reproducible.summary.contains("놓칠 수 있습니다"))
    }

    @Test func degenerateValuesAreClamped() {
        #expect(WhisperKitEngine.Options(concurrentWorkerCount: 0).concurrentWorkerCount == 1)
        #expect(WhisperKitEngine.Options(temperatureFallbackCount: -3).temperatureFallbackCount == 0)
    }
}
