import Foundation

/// The local models offered in Settings — the same two the cloud engine lists, so switching
/// engines doesn't change which model you asked for.
///
/// Raw values are WhisperKit variant folders in `argmaxinc/whisperkit-coreml`, verified against
/// the repository listing. Both use the `_turbo` folder: in WhisperKit's naming that suffix is a
/// **macOS compute optimisation of the same weights**, not a different model — which is why
/// `large-v3` maps to `openai_whisper-large-v3_turbo` and not to the plain folder. This app is
/// macOS-only, so the optimised variant is always the right one.
public enum WhisperModel: String, CaseIterable, Sendable, Codable {
    /// Whisper large-v3. The default, because accuracy is the point of this app.
    case largeV3 = "openai_whisper-large-v3_turbo"
    /// Whisper large-v3-turbo: large-v3 with its decoder pruned from 32 layers to 4, then
    /// finetuned. Much faster and half the download, at a small cost in accuracy — the choice for
    /// a smaller disk or a faster turnaround.
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo"

    public static let `default` = WhisperModel.largeV3

    public var identifier: String { rawValue }

    /// Shown in Settings, matching how the models are named everywhere else.
    public var displayName: String {
        switch self {
        case .largeV3: "large-v3"
        case .largeV3Turbo: "large-v3-turbo"
        }
    }

    /// Approximate download, in megabytes, from the repository listing. Shown next to the name so
    /// the cost of switching is visible before the download starts.
    public var downloadSizeMB: Int {
        switch self {
        case .largeV3: 3_047
        case .largeV3Turbo: 1_563
        }
    }

    /// The one line Settings shows under the name. It has to answer "why would I pick the other
    /// one?", because the difference is real: the two models share an audio encoder byte for byte,
    /// and differ in the decoder — 32 layers against 4.
    public var summary: String {
        switch self {
        case .largeV3: "가장 정확합니다. 기본값."
        case .largeV3Turbo: "더 빠르고 용량이 절반입니다. 정확도는 조금 낮습니다."
        }
    }

    /// e.g. "3.0 GB".
    public var downloadSizeDescription: String {
        String(format: "%.1f GB", Double(downloadSizeMB) / 1024)
    }

    public static let repository = "argmaxinc/whisperkit-coreml"

    /// `~/Library/Application Support/FCPCaption/models`
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "FCPCaption/models", directoryHint: .isDirectory)
    }
}
