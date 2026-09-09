import AVFoundation
import Foundation

/// Pulls the audio a transcription engine needs out of the original media, with AVFoundation only
/// — no ffmpeg, per spec §7.
///
/// Video files are the normal case here, and they are exactly what `AVAudioFile` (which WhisperKit
/// uses to load audio) cannot open. So this reads through `AVAssetReader` and writes a plain
/// 16 kHz mono WAV: the rate Whisper works at, so nothing downstream has to resample.
public struct AudioExtractor: Sendable {
    public struct Options: Sendable, Equatable {
        /// Whisper's native rate. Extracting at anything else only adds a resample.
        public var sampleRate: Double
        public var channels: Int

        public init(sampleRate: Double = 16_000, channels: Int = 1) {
            self.sampleRate = sampleRate
            self.channels = channels
        }

        public static let whisper = Options()
    }

    public var options: Options

    public init(options: Options = .whisper) {
        self.options = options
    }

    /// Extracts `range` (defaults to the whole asset) into a WAV file at `output`.
    ///
    /// - Returns: the duration actually written, which is what caption times are relative to.
    @discardableResult
    public func extract(
        from source: URL,
        range: CMTimeRange? = nil,
        to output: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> TimeInterval {
        let asset = AVURLAsset(url: source)

        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioExtractionError.noAudioTrack(source)
        }
        let assetDuration = try await asset.load(.duration)
        let timeRange = try clamped(range, within: assetDuration)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: options.sampleRate,
            AVNumberOfChannelsKey: options.channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(readerOutput) else { throw AudioExtractionError.unreadable(source) }
        reader.add(readerOutput)

        // AVAssetWriter fails with a bare "Cannot create file" if the directory isn't there.
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: options.sampleRate,
            AVNumberOfChannelsKey: options.channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw AudioExtractionError.unwritable(output) }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw AudioExtractionError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.startWriting() else {
            throw AudioExtractionError.writeFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let total = timeRange.duration.seconds
        let queue = DispatchQueue(label: "fcpcaption.audio-extract")
        // AVAssetReader/Writer aren't Sendable, but the writer drives us from its own queue and
        // cancellation arrives from another task. Boxing says "these crossings are deliberate"
        // in one place, instead of leaving the same warning at five call sites.
        let pipeline = UncheckedBox((reader: reader, readerOutput: readerOutput, writer: writer, input: writerInput))

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pipeline.value.input.requestMediaDataWhenReady(on: queue) {
                    while pipeline.value.input.isReadyForMoreMediaData {
                        if Task.isCancelled {
                            pipeline.value.reader.cancelReading()
                            pipeline.value.input.markAsFinished()
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        guard let buffer = pipeline.value.readerOutput.copyNextSampleBuffer() else {
                            pipeline.value.input.markAsFinished()
                            // The reader stopping for any reason other than "finished" is a
                            // failure, not an early end: a short file would otherwise look fine.
                            if pipeline.value.reader.status == .failed {
                                continuation.resume(throwing: AudioExtractionError.readFailed(
                                    pipeline.value.reader.error?.localizedDescription ?? "unknown"))
                            } else {
                                continuation.resume()
                            }
                            return
                        }
                        if total > 0 {
                            let elapsed = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                            progress(min(1, max(0, elapsed / total)))
                        }
                        if !pipeline.value.input.append(buffer) {
                            pipeline.value.reader.cancelReading()
                            pipeline.value.input.markAsFinished()
                            continuation.resume(throwing: AudioExtractionError.writeFailed(
                                pipeline.value.writer.error?.localizedDescription ?? "unknown"))
                            return
                        }
                    }
                }
            }
        } onCancel: {
            pipeline.value.reader.cancelReading()
        }

        await writer.finishWriting()
        if writer.status != .completed {
            throw AudioExtractionError.writeFailed(writer.error?.localizedDescription ?? "unknown")
        }
        progress(1)
        return total
    }

    /// A temporary WAV path that the caller owns and should delete when done.
    public static func temporaryOutputURL(named name: String = UUID().uuidString) -> URL {
        URL(filePath: NSTemporaryDirectory())
            .appending(path: "FCPCaption", directoryHint: .isDirectory)
            .appending(path: "\(name).wav")
    }

    private func clamped(_ range: CMTimeRange?, within duration: CMTime) throws -> CMTimeRange {
        guard let range, range.duration.seconds > 0 else {
            return CMTimeRange(start: .zero, duration: duration)
        }
        let start = CMTimeMaximum(range.start, .zero)
        guard start < duration else { throw AudioExtractionError.rangeOutsideMedia }
        let end = CMTimeMinimum(CMTimeAdd(start, range.duration), duration)
        return CMTimeRange(start: start, end: end)
    }
}

/// A deliberate, documented crossing of a non-Sendable value between concurrency domains.
private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

public enum AudioExtractionError: LocalizedError, Equatable {
    case noAudioTrack(URL)
    case unreadable(URL)
    case unwritable(URL)
    case readFailed(String)
    case writeFailed(String)
    case rangeOutsideMedia

    public var errorDescription: String? {
        switch self {
        case let .noAudioTrack(url):
            "이 클립에는 오디오가 없습니다: \(url.lastPathComponent)"
        case let .unreadable(url):
            "오디오를 읽을 수 없는 형식입니다: \(url.lastPathComponent)"
        case let .unwritable(url):
            "오디오를 저장할 수 없습니다: \(url.lastPathComponent)"
        case let .readFailed(detail):
            "오디오를 읽는 중 실패했습니다. (\(detail))"
        case let .writeFailed(detail):
            "오디오를 저장하는 중 실패했습니다. (\(detail))"
        case .rangeOutsideMedia:
            "클립 구간이 원본 미디어 범위를 벗어났습니다."
        }
    }
}
