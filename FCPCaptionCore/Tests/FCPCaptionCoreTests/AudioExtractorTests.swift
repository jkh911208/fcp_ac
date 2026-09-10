import AVFoundation
import Foundation
import Testing
@testable import FCPCaptionCore

struct AudioExtractorTests {
    /// A real audio file to read from — 44.1 kHz stereo, the shape phone footage arrives in,
    /// so the extractor has both a rate and a channel count to actually change.
    private func makeSource(seconds: Double = 3, sampleRate: Double = 44_100) throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "fcpcaption-source-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = 0.25 * sin(2 * .pi * 440 * Double(frame) / sampleRate).float
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test func extractsSixteenKilohertzMono() async throws {
        let source = try makeSource(seconds: 2)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = AudioExtractor.temporaryOutputURL()
        defer { try? FileManager.default.removeItem(at: output) }

        let duration = try await AudioExtractor().extract(from: source, to: output)

        #expect(abs(duration - 2) < 0.05)
        let written = try AVAudioFile(forReading: output)
        #expect(written.fileFormat.sampleRate == 16_000)
        #expect(written.fileFormat.channelCount == 1)
        #expect(abs(Double(written.length) / 16_000 - 2) < 0.05)
    }

    @Test func extractsOnlyTheRequestedRange() async throws {
        let source = try makeSource(seconds: 5)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = AudioExtractor.temporaryOutputURL()
        defer { try? FileManager.default.removeItem(at: output) }

        let range = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600),
                                duration: CMTime(seconds: 2, preferredTimescale: 600))
        let duration = try await AudioExtractor().extract(from: source, range: range, to: output)

        #expect(abs(duration - 2) < 0.05)
        let written = try AVAudioFile(forReading: output)
        #expect(abs(Double(written.length) / 16_000 - 2) < 0.1)
    }

    @Test func aRangeRunningPastTheEndIsTrimmedNotRefused() async throws {
        let source = try makeSource(seconds: 2)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = AudioExtractor.temporaryOutputURL()
        defer { try? FileManager.default.removeItem(at: output) }

        // A clip whose FCPXML duration runs a little past the media happens with conformed rates.
        let range = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600),
                                duration: CMTime(seconds: 10, preferredTimescale: 600))
        let duration = try await AudioExtractor().extract(from: source, range: range, to: output)
        #expect(abs(duration - 1) < 0.05)
    }

    @Test func reportsProgressToCompletion() async throws {
        let source = try makeSource(seconds: 2)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = AudioExtractor.temporaryOutputURL()
        defer { try? FileManager.default.removeItem(at: output) }

        nonisolated(unsafe) var last = -1.0
        try await AudioExtractor().extract(from: source, to: output) { fraction in
            last = fraction
        }
        #expect(last == 1.0)
    }

    @Test func aFileWithNoAudioIsAClearError() async throws {
        let empty = URL(filePath: NSTemporaryDirectory())
            .appending(path: "fcpcaption-empty-\(UUID().uuidString).mov")
        try Data("not media".utf8).write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }

        await #expect(throws: (any Error).self) {
            try await AudioExtractor().extract(from: empty, to: AudioExtractor.temporaryOutputURL())
        }
    }

    @Test func aRangeThatStartsPastTheEndIsRefused() async throws {
        let source = try makeSource(seconds: 1)
        defer { try? FileManager.default.removeItem(at: source) }
        let range = CMTimeRange(start: CMTime(seconds: 5, preferredTimescale: 600),
                                duration: CMTime(seconds: 1, preferredTimescale: 600))
        // The numbers are the point of this error: they are what tells a user whether the media
        // was swapped for a proxy or the clip is retimed.
        await #expect {
            try await AudioExtractor().extract(from: source, range: range, to: AudioExtractor.temporaryOutputURL())
        } throws: { error in
            guard case let .rangeOutsideMedia(file, start, length, mediaDuration) =
                    error as? AudioExtractionError else { return false }
            return file == source.lastPathComponent
                && start == 5
                && length == 1
                && abs(mediaDuration - 1) < 0.05
        }
    }

    @Test("the message names the file and all three numbers")
    func theMessageIsActionable() throws {
        let message = try #require(AudioExtractionError.rangeOutsideMedia(
            file: "03.mp4", start: 37.07, length: 2.73, mediaDuration: 36
        ).errorDescription)
        for expected in ["03.mp4", "37.07초", "2.73초", "36.00초"] {
            #expect(message.contains(expected), "missing \(expected) in: \(message)")
        }
    }
}

private extension Double {
    var float: Float { Float(self) }
}
