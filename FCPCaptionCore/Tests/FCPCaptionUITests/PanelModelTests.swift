import AVFoundation
import Foundation
import Testing
@testable import FCPCaptionCore
@testable import FCPCaptionUI

/// The panel's states, driven without AppKit, Final Cut Pro, a model download or a network.
@MainActor
struct PanelModelTests {
    /// Returns fixed words after an optional pause, so cancellation has something to interrupt.
    final class StubEngine: TranscriptionEngine, @unchecked Sendable {
        let id = "stub"
        let words: [TranscriptWord]
        let delay: Duration
        init(words: [TranscriptWord], delay: Duration = .zero) {
            self.words = words
            self.delay = delay
        }
        func transcribe(
            audio: URL,
            language: String?,
            progress: @escaping @Sendable (TranscriptionPhase, Double) -> Void
        ) async throws -> [TranscriptWord] {
            if delay > .zero { try await Task.sleep(for: delay) }
            progress(.transcribing, 1)
            return words
        }
        func cancel() {}
    }

    private let words = [
        TranscriptWord(text: "안녕하세요.", start: 0.2, end: 1.2),
        TranscriptWord(text: "반갑습니다.", start: 1.5, end: 2.4),
    ]

    /// A 6-second silent WAV and an FCPXML pointing at it.
    private func makeDocument() throws -> (data: Data, media: URL) {
        let media = URL(filePath: NSTemporaryDirectory())
            .appending(path: "fcpcaption-panel-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: media, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 6)!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.14">
          <resources>
            <format id="r1" frameDuration="1001/30000s"/>
            <asset id="r2" name="인터뷰" start="0s" duration="6s" format="r1" hasAudio="1">
              <media-rep kind="original-media" src="\(media.absoluteString)"/>
            </asset>
          </resources>
          <library><event name="E"><project name="P"><sequence format="r1" duration="6s"><spine>
            <asset-clip ref="r2" offset="0s" name="인터뷰" start="0s" duration="6s"/>
          </spine></sequence></project></event></library>
        </fcpxml>
        """
        return (Data(xml.utf8), media)
    }

    private func makeModel(
        engine: StubEngine,
        deliver: (@Sendable (Data, ClipRef) throws -> URL)? = nil
    ) -> PanelModel {
        PanelModel(
            makePipeline: { _ in CaptionPipeline(engine: engine) },
            deliver: deliver ?? { data, clip in
                let url = URL(filePath: NSTemporaryDirectory())
                    .appending(path: "\(clip.name)-\(UUID().uuidString).fcpxml")
                try data.write(to: url)
                return url
            }
        )
    }

    @Test func startsWaitingForADrop() {
        #expect(makeModel(engine: StubEngine(words: words)).state == .waiting)
    }

    @Test func aDroppedDocumentShowsTheClip() throws {
        let (data, media) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: media) }

        let model = makeModel(engine: StubEngine(words: words))
        model.receive(data)

        guard case let .ready(clips, hasTimeline) = model.state else {
            Issue.record("expected .ready, got \(model.state)")
            return
        }
        #expect(clips.count == 1)
        #expect(clips[0].name == "인터뷰")
        #expect(abs(clips[0].durationSeconds - 6) < 0.01)
        #expect(hasTimeline)   // the test document is a project, so it has a sequence
    }

    @Test func runningEndsInFinishedWithTheCaptionCount() async throws {
        let (data, media) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: media) }

        let model = makeModel(engine: StubEngine(words: words))
        model.receive(data)
        model.start()

        try await untilFinished(model)
        guard case let .finished(finished) = model.state else {
            Issue.record("expected .finished, got \(model.state)")
            return
        }
        #expect(finished.captionCount == 2)
        #expect(finished.clipName == "인터뷰")
        #expect(FileManager.default.fileExists(atPath: finished.output.path(percentEncoded: false)))
        try? FileManager.default.removeItem(at: finished.output)
    }

    @Test func cancellingReturnsToTheClipNotToAnEmptyPanel() async throws {
        let (data, media) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: media) }

        let model = makeModel(engine: StubEngine(words: words, delay: .seconds(5)))
        model.receive(data)
        model.start()
        model.cancel()

        try await until(model) { if case .ready = $0 { return true } else { return false } }
        // Cancelling is not an error, and it does not throw away the dropped clip.
        guard case .ready = model.state else {
            Issue.record("expected .ready after cancel, got \(model.state)")
            return
        }
    }

    @Test func resetForgetsTheClip() throws {
        let (data, media) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: media) }

        let model = makeModel(engine: StubEngine(words: words))
        model.receive(data)
        model.reset()
        #expect(model.state == .waiting)
    }

    @Test func aDocumentWithNoAudioFailsWithAKoreanMessageAndNoRetry() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.14">
          <resources><format id="r1" frameDuration="1001/30000s"/>
            <asset id="r2" name="스틸" start="0s" duration="6s" format="r1" hasVideo="1"/></resources>
          <library><event name="E"><project name="P"><sequence format="r1" duration="6s"><spine>
            <asset-clip ref="r2" offset="0s" name="스틸" start="0s" duration="6s"/>
          </spine></sequence></project></event></library>
        </fcpxml>
        """
        let model = makeModel(engine: StubEngine(words: words))
        model.receive(Data(xml.utf8))

        guard case let .failed(message, canRetry) = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
        #expect(message == "오디오가 있는 클립이 없습니다.")
        #expect(!canRetry)   // retrying the same drop cannot help
    }

    @Test func garbageIsRejectedWithAKoreanMessage() {
        let model = makeModel(engine: StubEngine(words: words))
        model.receive(Data("not xml at all".utf8))
        guard case let .failed(message, _) = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
        #expect(message.contains("FCPXML"))
    }

    @Test func aFailureDuringTheRunOffersARetryThatKeepsTheClip() async throws {
        let (data, media) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: media) }

        // Silence: the engine returns nothing, which the pipeline reports rather than writing an
        // empty document.
        let model = makeModel(engine: StubEngine(words: []))
        model.receive(data)
        model.start()

        try await until(model) { if case .failed = $0 { return true } else { return false } }
        guard case let .failed(message, canRetry) = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
        #expect(message.contains("음성"))
        #expect(canRetry)
    }

    @Test func progressOnlyMovesWhileTheJobIsRunning() async throws {
        let (data, media) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: media) }

        let model = makeModel(engine: StubEngine(words: words))
        model.receive(data)
        model.start()
        try await untilFinished(model)

        // A late progress callback must not drag a finished panel back into .working.
        guard case .finished = model.state else {
            Issue.record("expected .finished, got \(model.state)")
            return
        }
    }

    // MARK: - Waiting

    private func until(
        _ model: PanelModel,
        _ predicate: (PanelModel.State) -> Bool,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate(model.state) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out in state \(model.state)")
    }

    private func untilFinished(_ model: PanelModel) async throws {
        try await until(model) {
            switch $0 {
            case .finished, .failed: true
            default: false
            }
        }
    }
}

/// The name offered in the save panel. A save panel appends the extension itself, so handing it
/// one too produced "IMG_2194.itt.itt".
@MainActor
struct CaptionFileNameTests {
    @Test func theExtensionIsLeftToTheSavePanel() {
        #expect(PanelModel.fileBaseName(for: "IMG_2194") == "IMG_2194")
        #expect(PanelModel.fileBaseName(for: "IMG_2194.itt") == "IMG_2194")
        #expect(PanelModel.fileBaseName(for: "clip.ITT") == "clip")
    }

    @Test func aClipNameIsMadeSafeForAFileName() {
        #expect(PanelModel.fileBaseName(for: "A/B") == "A-B")
        #expect(PanelModel.fileBaseName(for: "17:12 촬영") == "17-12 촬영")
    }

    @Test func anEmptyOrMissingNameFallsBack() {
        #expect(PanelModel.fileBaseName(for: nil) == "자막")
        #expect(PanelModel.fileBaseName(for: "") == "자막")
        #expect(PanelModel.fileBaseName(for: ".itt") == "자막")
    }
}
