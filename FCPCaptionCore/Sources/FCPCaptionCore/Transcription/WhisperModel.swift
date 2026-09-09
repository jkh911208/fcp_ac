import Foundation

/// The local models we offer. Raw values are WhisperKit variant folder names in
/// `argmaxinc/whisperkit-coreml` — verified against the repo listing, not guessed.
public enum WhisperModel: String, CaseIterable, Sendable, Codable {
    /// large-v3-turbo. The default: near large-v3 quality for Korean at a fraction of the time.
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo"
    /// A smaller fallback for machines where the turbo model is too heavy.
    case small = "openai_whisper-small"

    public var identifier: String { rawValue }

    /// Shown in Settings.
    public var displayName: String {
        switch self {
        case .largeV3Turbo: "large-v3-turbo"
        case .small: "small"
        }
    }

    public static let repository = "argmaxinc/whisperkit-coreml"

    /// `~/Library/Application Support/FCPCaption/models`
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "FCPCaption/models", directoryHint: .isDirectory)
    }
}
