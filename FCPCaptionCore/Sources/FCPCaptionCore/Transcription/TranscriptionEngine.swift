import Foundation

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
    ///   - progress: 0...1, called on an arbitrary thread.
    func transcribe(
        audio: URL,
        language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptWord]

    func cancel()
}
