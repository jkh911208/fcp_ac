import Foundation

/// Which part of the work a progress report belongs to.
///
/// The spec's engine signature had a bare fraction, written before anyone had watched a 3 GB model
/// load. Getting ready takes minutes on a first run, and the two halves of it are different: a
/// download can say how many bytes and how fast, while a CoreML load and the first Neural Engine
/// compile report nothing at all. A bar frozen at 12% is indistinguishable from a hang, so the
/// phases are named separately and the UI shows what each one can honestly show.
public enum TranscriptionPhase: Sendable, Equatable {
    /// Fetching the model. Happens once per model per machine.
    case downloadingModel(downloaded: Int64, total: Int64, bytesPerSecond: Double)
    /// Loading into CoreML and, the first time, compiling for the Neural Engine. **No progress
    /// exists for this** — it is minutes of silence, once.
    case loadingModel
    case transcribing
}

/// One transcription backend: on-device WhisperKit, or an OpenAI-compatible HTTP endpoint.
///
/// Implementations return words on the *clip's* timeline (chunk offsets already applied) and must
/// honour both cooperative `Task` cancellation and an explicit `cancel()`.
public protocol TranscriptionEngine: AnyObject, Sendable {
    /// Stable identifier stored in Settings, e.g. `"whisperkit"` / `"openrouter"`.
    var id: String { get }

    /// - Parameters:
    ///   - audio: a local audio file the engine can read.
    ///   - language: BCP-47-ish language code (`"ko"`), or `nil` to let the engine detect it.
    ///   - progress: the phase and its 0...1 fraction, called on an arbitrary thread. During
    ///     `.preparingModel` the fraction may sit still: a CoreML load reports nothing.
    func transcribe(
        audio: URL,
        language: String?,
        progress: @escaping @Sendable (TranscriptionPhase, Double) -> Void
    ) async throws -> [TranscriptWord]

    func cancel()
}
