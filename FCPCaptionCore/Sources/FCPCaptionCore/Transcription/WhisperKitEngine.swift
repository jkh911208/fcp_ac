import AVFoundation
import Foundation
import WhisperKit

/// On-device transcription. The model is downloaded once into
/// `~/Library/Application Support/FCPCaption/models` and reused; nothing leaves the Mac.
///
/// Thread safety: the pipeline and the cancel flag are guarded by `lock`; everything else is
/// immutable, which is why this can be `@unchecked Sendable`.
public final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {
    public let id = "whisperkit"
    public let model: WhisperModel

    private let modelDirectory: URL
    private let lock = NSLock()
    private var pipeline: WhisperKit?
    private var cancelRequested = false

    /// Share of the reported progress spent getting the model ready. The first run downloads
    /// ~600MB, later runs skip straight past it.
    private static let preparationShare = 0.15

    public init(model: WhisperModel = .largeV3Turbo, modelDirectory: URL = WhisperModel.defaultDirectory) {
        self.model = model
        self.modelDirectory = modelDirectory
    }

    // MARK: - TranscriptionEngine

    public func transcribe(
        audio: URL,
        language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptWord] {
        setCancelRequested(false)

        return try await withTaskCancellationHandler {
            let pipeline = try await preparedPipeline { fraction in
                progress(fraction * Self.preparationShare)
            }
            try checkCancellation()

            let windows = try await expectedWindowCount(of: audio)
            let options = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: language,
                detectLanguage: language == nil,
                skipSpecialTokens: true,
                wordTimestamps: true
            )

            let callback: TranscriptionCallback = { [weak self] update in
                guard let self else { return false }
                if self.isCancelRequested { return false }
                let fraction = min(0.99, Double(update.windowId + 1) / windows)
                progress(Self.preparationShare + (1 - Self.preparationShare) * fraction)
                return true
            }

            let results: [TranscriptionResult]
            do {
                results = try await pipeline.transcribe(
                    audioPath: audio.path(percentEncoded: false),
                    decodeOptions: options,
                    callback: callback
                )
            } catch {
                try checkCancellation()
                throw TranscriptionError.engineFailure(String(describing: error))
            }
            try checkCancellation()

            progress(1.0)
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
    public func prepare(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        _ = try await preparedPipeline(progress: progress)
    }

    private func preparedPipeline(progress: @escaping @Sendable (Double) -> Void) async throws -> WhisperKit {
        if let existing = loadedPipeline {
            progress(1.0)
            return existing
        }

        do {
            let folder = try await WhisperKit.download(
                variant: model.identifier,
                downloadBase: modelDirectory,
                from: WhisperModel.repository,
                progressCallback: { downloadProgress in
                    progress(min(0.95, downloadProgress.fractionCompleted))
                }
            )
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
            progress(1.0)
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

    /// Whisper decodes in 30-second windows, so the window count is what progress can be measured
    /// against. An unreadable duration is not fatal here — it only costs a progress bar.
    private func expectedWindowCount(of audio: URL) async throws -> Double {
        let asset = AVURLAsset(url: audio)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else {
            throw TranscriptionError.audioUnreadable(audio)
        }
        return max(1, (duration.seconds / 30).rounded(.up))
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
