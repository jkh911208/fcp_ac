import AVFoundation
import Foundation
import WhisperKit

/// On-device transcription. The model is downloaded once into
/// `~/Library/Application Support/FCPCaption/models` and reused; nothing leaves the Mac.
///
/// Thread safety: the pipeline and the cancel flag are guarded by `lock`; everything else is
/// immutable, which is why this can be `@unchecked Sendable`.
public final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {
    /// Decoding settings, exposed because they trade reproducibility against completeness and
    /// only the person editing knows which they want.
    ///
    /// Measured on a 3-minute Korean clip, each setting run twice (2026-09-09):
    ///
    /// | Setting | Time | Same output twice? | Captions |
    /// |---|---|---|---|
    /// | 16 workers, 5 retries (default) | 22.3s / 23.0s | no, 91.8% alike | 47 / 41 |
    /// | 1 worker, 5 retries | 18.9s / 21.2s | no, 82.2% alike | 32 / 46 |
    /// | 16 workers, **0 retries** | 14.8s / 14.0s | **yes, byte-identical** | 32 / 32 |
    ///
    /// The retries are what make a run unrepeatable — above zero temperature the decoder samples,
    /// and each window prompts the next, so one sampled difference propagates. Fewer workers do
    /// not help; they made it worse.
    ///
    /// **But turning the retries off loses speech.** In that same clip the first 117 seconds came
    /// out identical either way, and then the no-retry run went almost silent for the remaining
    /// minute — a third of the clip, gone, which is also why it looked faster. The retries exist
    /// to recover a window whose decode has collapsed, and without them the collapse is permanent.
    ///
    /// So the defaults stay WhisperKit's. A caption that shifts slightly between runs is a
    /// nuisance; a minute of missing dialogue is a broken subtitle track.
    public struct Options: Sendable, Equatable, Codable {
        /// Windows decoded at once. WhisperKit's macOS default is 16.
        public var concurrentWorkerCount: Int
        /// Retries at rising temperature when a window's decode looks degenerate.
        ///
        /// Set to 0 for a run that repeats exactly — at the cost of losing whatever the retries
        /// would have recovered.
        public var temperatureFallbackCount: Int

        public init(concurrentWorkerCount: Int = 16, temperatureFallbackCount: Int = 5) {
            self.concurrentWorkerCount = max(1, concurrentWorkerCount)
            self.temperatureFallbackCount = max(0, temperatureFallbackCount)
        }

        /// The default: recovers difficult passages, and does not repeat exactly.
        public static let complete = Options()

        /// Byte-identical output on every run, and it will drop speech it cannot decode cleanly.
        public static let reproducible = Options(concurrentWorkerCount: 16, temperatureFallbackCount: 0)

        /// Whether two runs with these settings produce the same text.
        public var isReproducible: Bool { temperatureFallbackCount == 0 }

        /// The line Settings shows under the toggle.
        public var summary: String {
            isReproducible
                ? "매번 같은 결과가 나옵니다. 대신 알아듣기 어려운 구간을 통째로 놓칠 수 있습니다."
                : "어려운 구간을 여러 번 시도해 살려냅니다. 대신 같은 영상을 다시 돌리면 결과가 조금 달라집니다."
        }
    }

    public let id = "whisperkit"
    public let model: WhisperModel
    public var options: Options

    private let modelDirectory: URL
    private let lock = NSLock()
    private var pipeline: WhisperKit?
    private var cancelRequested = false

    public init(
        model: WhisperModel = .default,
        modelDirectory: URL = WhisperModel.defaultDirectory,
        options: Options = .init()
    ) {
        self.model = model
        self.modelDirectory = modelDirectory
        self.options = options
    }

    // MARK: - TranscriptionEngine

    public func transcribe(
        audio: URL,
        language: String?,
        progress: @escaping @Sendable (TranscriptionPhase, Double) -> Void
    ) async throws -> [TranscriptWord] {
        setCancelRequested(false)

        return try await withTaskCancellationHandler {
            let pipeline = try await preparedPipeline { phase in progress(phase, 0) }
            try checkCancellation()
            progress(.transcribing, 0)

            let duration = try await audioDuration(of: audio)
            let decodeOptions = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: language,
                temperatureFallbackCount: options.temperatureFallbackCount,
                detectLanguage: language == nil,
                skipSpecialTokens: true,
                wordTimestamps: true,
                concurrentWorkerCount: options.concurrentWorkerCount
            )

            // Progress from how far into the audio the decoder has reached, which is the real
            // thing — window counts jump around with 16 concurrent workers. Monotonic, because a
            // bar that goes backwards reads as a bug.
            let furthest = Furthest()
            pipeline.segmentDiscoveryCallback = { segments in
                guard duration > 0, let end = segments.map(\.end).max() else { return }
                let fraction = furthest.advance(to: min(0.99, Double(end) / duration))
                progress(.transcribing, fraction)
            }
            let callback: TranscriptionCallback = { [weak self] _ in
                guard let self else { return false }
                return !self.isCancelRequested
            }

            let results: [TranscriptionResult]
            do {
                results = try await pipeline.transcribe(
                    audioPath: audio.path(percentEncoded: false),
                    decodeOptions: decodeOptions,
                    callback: callback
                )
            } catch {
                try checkCancellation()
                throw TranscriptionError.engineFailure(String(describing: error))
            }
            try checkCancellation()

            pipeline.segmentDiscoveryCallback = nil
            progress(.transcribing, 1)
            return Self.words(from: results)
        } onCancel: {
            cancel()
        }
    }

    public func cancel() {
        setCancelRequested(true)
    }

    // MARK: - Model

    /// Downloads the model if it isn't on disk yet and loads it. Safe to call repeatedly — the
    /// loaded pipeline is cached, and the download step skips files that are already present.
    public func prepare(progress: @escaping @Sendable (TranscriptionPhase) -> Void = { _ in }) async throws {
        _ = try await preparedPipeline(progress: progress)
    }

    private func preparedPipeline(progress: @escaping @Sendable (TranscriptionPhase) -> Void) async throws -> WhisperKit {
        if let existing = loadedPipeline { return existing }

        do {
            // The download reports a fraction, not bytes, so the byte counts come from the model's
            // known size — accurate to a few MB and far more useful than a bare percentage.
            let total = Int64(model.downloadSizeMB) * 1_048_576
            let rate = TransferRate()
            let folder = try await WhisperKit.download(
                variant: model.identifier,
                downloadBase: modelDirectory,
                from: WhisperModel.repository,
                progressCallback: { downloadProgress in
                    let downloaded = Int64(Double(total) * min(1, downloadProgress.fractionCompleted))
                    progress(.downloadingModel(
                        downloaded: downloaded,
                        total: total,
                        bytesPerSecond: rate.observe(downloaded)
                    ))
                }
            )
            progress(.loadingModel)
            try checkCancellation()

            let config = WhisperKitConfig(
                modelFolder: folder.path(percentEncoded: false),
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            )
            let pipeline = try await WhisperKit(config)
            store(pipeline: pipeline)
            return pipeline
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.modelUnavailable(
                model: model.displayName,
                underlying: String(describing: error)
            )
        }
    }

    // MARK: - Result mapping

    static func words(from results: [TranscriptionResult]) -> [TranscriptWord] {
        segments(from: results).flatMap { $0.approximateWords() }
    }

    /// WhisperKit segments in our own types. `words` stays empty when the model returned no word
    /// timings, which is what makes the character-proportional fallback kick in downstream.
    static func segments(from results: [TranscriptionResult]) -> [TranscriptSegment] {
        results.flatMap(\.segments).map { segment in
            TranscriptSegment(
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                start: TimeInterval(segment.start),
                end: TimeInterval(segment.end),
                words: (segment.words ?? []).compactMap { timing in
                    let text = timing.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return TranscriptWord(
                        text: text,
                        start: TimeInterval(timing.start),
                        end: TimeInterval(max(timing.start, timing.end))
                    )
                }
            )
        }
        .filter { !$0.text.isEmpty }
    }

    // MARK: - Helpers

    private func audioDuration(of audio: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: audio)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else {
            throw TranscriptionError.audioUnreadable(audio)
        }
        return duration.seconds
    }

    private var loadedPipeline: WhisperKit? {
        lock.withLock { pipeline }
    }

    private func store(pipeline: WhisperKit) {
        lock.withLock { self.pipeline = pipeline }
    }

    private var isCancelRequested: Bool {
        lock.withLock { cancelRequested }
    }

    private func setCancelRequested(_ value: Bool) {
        lock.withLock { cancelRequested = value }
    }

    private func checkCancellation() throws {
        if isCancelRequested || Task.isCancelled { throw CancellationError() }
    }
}

/// Keeps a fraction from going backwards when reports arrive out of order — with 16 concurrent
/// workers they do, and a progress bar that jumps backwards reads as a bug.
private final class Furthest: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0

    func advance(to fraction: Double) -> Double {
        lock.withLock {
            value = max(value, fraction)
            return value
        }
    }
}


/// A smoothed bytes-per-second estimate. Raw deltas between callbacks swing wildly enough to be
/// useless on screen, so each sample is blended into the last.
private final class TransferRate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBytes: Int64 = 0
    private var lastTime = ContinuousClock.now
    private var smoothed: Double = 0

    func observe(_ bytes: Int64) -> Double {
        lock.withLock {
            let now = ContinuousClock.now
            let seconds = Double((now - lastTime).components.seconds)
                + Double((now - lastTime).components.attoseconds) / 1e18
            guard seconds > 0.25, bytes >= lastBytes else { return smoothed }
            let rate = Double(bytes - lastBytes) / seconds
            smoothed = smoothed == 0 ? rate : smoothed * 0.7 + rate * 0.3
            lastBytes = bytes
            lastTime = now
            return smoothed
        }
    }
}
