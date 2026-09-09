import AVFoundation
import Foundation
import Testing
@testable import FCPCaptionCore

/// The whole path — FCPXML in, captioned FCPXML out — with a stub engine, so it runs offline in
/// milliseconds and no test ever downloads a model or reaches a network.
struct CaptionPipelineTests {
    /// Returns fixed words, and records what it was asked to transcribe.
    final class StubEngine: TranscriptionEngine, @unchecked Sendable {
        let id = "stub"
        let words: [TranscriptWord]
        private let lock = NSLock()
        private var _audio: URL?
        private var _audioSeconds: Double?
        private var _language: String??
        private var _cancelled = false

        init(words: [TranscriptWord]) { self.words = words }

        var audio: URL? { lock.withLock { _audio } }
        /// Measured while the file still exists — the pipeline deletes its temporary audio as
        /// soon as it returns, which is the behaviour we want and a trap for tests.
        var audioSeconds: Double? { lock.withLock { _audioSeconds } }
        var language: String?? { lock.withLock { _language } }
        var wasCancelled: Bool { lock.withLock { _cancelled } }

        func transcribe(
            audio: URL,
            language: String?,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws -> [TranscriptWord] {
            let seconds = (try? AVAudioFile(forReading: audio)).map { Double($0.length) / $0.fileFormat.sampleRate }
            lock.withLock { _audio = audio; _language = language; _audioSeconds = seconds }
            progress(0.5)
            progress(1)
            return words
        }

        func cancel() { lock.withLock { _cancelled = true } }
    }

    /// A 6-second silent WAV plus an FCPXML that points at it — the smallest thing that exercises
    /// audio extraction, since the extractor needs a real asset to read.
    private func makeProject(clipStart: Int = 0, clipDuration: Int = 6) throws -> (data: Data, media: URL) {
        let media = URL(filePath: NSTemporaryDirectory())
            .appending(path: "fcpcaption-pipeline-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: media, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44_100 * 10))!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.14">
          <resources>
            <format id="r1" frameDuration="1001/30000s" width="1920" height="1080"/>
            <asset id="r2" name="Take" start="0s" duration="10s" format="r1" hasAudio="1" audioSources="1">
              <media-rep kind="original-media" src="\(media.absoluteString)"/>
            </asset>
          </resources>
          <library><event name="E"><project name="P">
            <sequence format="r1" duration="\(clipDuration)s" tcStart="0s"><spine>
              <asset-clip ref="r2" offset="0s" name="Take" start="\(clipStart)s" duration="\(clipDuration)s" hasAudio="1"/>
            </spine></sequence>
          </project></event></library>
        </fcpxml>
        """
        return (Data(xml.utf8), media)
    }

    private let words = [
        TranscriptWord(text: "안녕하세요.", start: 0.2, end: 1.2),
        TranscriptWord(text: "오늘은", start: 1.4, end: 2.0),
        TranscriptWord(text: "날씨가", start: 2.1, end: 2.7),
        TranscriptWord(text: "좋네요.", start: 2.8, end: 3.6),
    ]

    @Test func theTemporaryAudioIsCleanedUp() async throws {
        let (data, media) = try makeProject()
        defer { try? FileManager.default.removeItem(at: media) }
        let engine = StubEngine(words: words)
        _ = try await CaptionPipeline(engine: engine).run(document: data)
        let extracted = try #require(engine.audio)
        #expect(!FileManager.default.fileExists(atPath: extracted.path(percentEncoded: false)))
    }

    @Test func producesCaptionsOnTheClipItWasGiven() async throws {
        let (data, media) = try makeProject()
        defer { try? FileManager.default.removeItem(at: media) }

        let engine = StubEngine(words: words)
        let result = try await CaptionPipeline(engine: engine).run(document: data)

        #expect(result.words == 4)
        #expect(result.captions.count == 2)          // the sentence break splits them
        #expect(result.clips.count == 1)
        #expect(result.clips[0].clip.name == "Take")

        let written = try FCPXMLReader().read(data: result.document)
        let captions = try #require(written.clips.first?.captions)
        #expect(captions.count == 2)
        #expect(captions.first?.text == "안녕하세요.")
        #expect(captions.allSatisfy { $0.role == "iTT?captionFormat=ITT.ko" })
    }

    @Test func transcribesOnlyThePartOfTheMediaTheClipUses() async throws {
        // The clip plays 4 seconds starting 3 seconds into a 10-second file.
        let (data, media) = try makeProject(clipStart: 3, clipDuration: 4)
        defer { try? FileManager.default.removeItem(at: media) }

        let engine = StubEngine(words: words)
        _ = try await CaptionPipeline(engine: engine).run(document: data)

        #expect(abs(try #require(engine.audioSeconds) - 4) < 0.15)
    }

    @Test func captionTimesAreOffsetByTheClipsStart() async throws {
        let (data, media) = try makeProject(clipStart: 3, clipDuration: 4)
        defer { try? FileManager.default.removeItem(at: media) }

        let result = try await CaptionPipeline(engine: StubEngine(words: words)).run(document: data)
        let caption = try #require(try FCPXMLReader().read(data: result.document).clips.first?.captions.first)
        // 0.2s into the transcript is 3.2s into the clip's own media time.
        #expect(abs(caption.offset.seconds - 3.2) < 0.05)
    }

    @Test func theLanguageReachesTheEngineAndTheRole() async throws {
        let (data, media) = try makeProject()
        defer { try? FileManager.default.removeItem(at: media) }

        let engine = StubEngine(words: words)
        let result = try await CaptionPipeline(engine: engine, language: "en").run(document: data)
        #expect(engine.language == "en")
        #expect(try FCPXMLReader().read(data: result.document).clips.first?.captions.first?.language == "en")
    }

    @Test func progressRunsForwardToOne() async throws {
        let (data, media) = try makeProject()
        defer { try? FileManager.default.removeItem(at: media) }

        final class Trace: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Double] = []
            func add(_ value: Double) { lock.withLock { values.append(value) } }
            var all: [Double] { lock.withLock { values } }
        }
        let trace = Trace()
        _ = try await CaptionPipeline(engine: StubEngine(words: words))
            .run(document: data) { _, fraction in trace.add(fraction) }

        let values = trace.all
        #expect(values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })   // never goes backwards
    }

    @Test func missingMediaIsNamedNotSwallowed() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.14">
          <resources>
            <format id="r1" frameDuration="1001/30000s"/>
            <asset id="r2" name="Take" start="0s" duration="10s" format="r1" hasAudio="1">
              <media-rep kind="original-media" src="file:///nowhere/missing.mov"/>
            </asset>
          </resources>
          <library><event name="E"><project name="P"><sequence format="r1" duration="6s"><spine>
            <asset-clip ref="r2" offset="0s" name="Take" start="0s" duration="6s"/>
          </spine></sequence></project></event></library>
        </fcpxml>
        """
        await #expect(throws: CaptionPipelineError.mediaMissing(URL(filePath: "/nowhere/missing.mov"))) {
            try await CaptionPipeline(engine: StubEngine(words: words)).run(document: Data(xml.utf8))
        }
    }

    @Test func silenceIsReportedRatherThanWritingAnEmptyDocument() async throws {
        let (data, media) = try makeProject()
        defer { try? FileManager.default.removeItem(at: media) }
        await #expect(throws: CaptionPipelineError.noSpeechFound) {
            try await CaptionPipeline(engine: StubEngine(words: [])).run(document: data)
        }
    }
}


/// Dragging a project hands over the whole timeline, so every audible clip on it gets captioned —
/// not just the first one. Found the hard way: a project with two clips only ever captioned one.
extension CaptionPipelineTests {
    /// Two clips on one spine, pointing at the same media at different offsets.
    private func makeTwoClipProject() throws -> (data: Data, media: URL) {
        let media = URL(filePath: NSTemporaryDirectory())
            .appending(path: "fcpcaption-two-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: media, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 20)!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.14">
          <resources>
            <format id="r1" frameDuration="1001/30000s"/>
            <asset id="r2" name="Take" start="0s" duration="20s" format="r1" hasAudio="1">
              <media-rep kind="original-media" src="\(media.absoluteString)"/>
            </asset>
          </resources>
          <library><event name="E"><project name="P">
            <sequence format="r1" duration="10s" tcStart="0s"><spine>
              <asset-clip ref="r2" offset="0s" name="첫 번째" start="0s" duration="5s"/>
              <asset-clip ref="r2" offset="5s" name="두 번째" start="12s" duration="5s"/>
            </spine></sequence>
          </project></event></library>
        </fcpxml>
        """
        return (Data(xml.utf8), media)
    }

    @Test func everyAudibleClipOnTheTimelineIsCaptioned() async throws {
        let (data, media) = try makeTwoClipProject()
        defer { try? FileManager.default.removeItem(at: media) }

        let result = try await CaptionPipeline(engine: StubEngine(words: words)).run(document: data)

        #expect(result.clips.count == 2)
        #expect(result.clips.map(\.clip.name) == ["첫 번째", "두 번째"])

        let written = try FCPXMLReader().read(data: result.document)
        #expect(written.clips.count == 2)
        #expect(written.clips.allSatisfy { !$0.captions.isEmpty })
    }

    // Trimmed-away footage is never transcribed: each clip is read only over the range it uses.
    // The second clip starts 12s into a 20s file, so its audio is the 12s–17s slice.
    @Test func onlyTheUsedRangeOfEachClipIsTranscribed() async throws {
        let (data, media) = try makeTwoClipProject()
        defer { try? FileManager.default.removeItem(at: media) }

        let engine = StubEngine(words: words)
        _ = try await CaptionPipeline(engine: engine).run(document: data)
        // The stub records the last clip it saw: 5 seconds, not the whole 20-second file.
        #expect(abs(try #require(engine.audioSeconds) - 5) < 0.2)
    }

    @Test func aClipWithNoSpeechDoesNotFailTheWholeRun() async throws {
        let (data, media) = try makeTwoClipProject()
        defer { try? FileManager.default.removeItem(at: media) }

        // Silence on one clip of several is ordinary b-roll; only total silence is an error.
        final class SilentOnSecond: TranscriptionEngine, @unchecked Sendable {
            let id = "stub"
            let words: [TranscriptWord]
            private let lock = NSLock()
            private var calls = 0
            init(words: [TranscriptWord]) { self.words = words }
            func transcribe(audio: URL, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptWord] {
                let first = lock.withLock { calls += 1; return calls == 1 }
                return first ? words : []
            }
            func cancel() {}
        }

        let result = try await CaptionPipeline(engine: SilentOnSecond(words: words)).run(document: data)
        #expect(result.clips.count == 2)
        #expect(!result.clips[0].captions.isEmpty)
        #expect(result.clips[1].captions.isEmpty)
    }
}
