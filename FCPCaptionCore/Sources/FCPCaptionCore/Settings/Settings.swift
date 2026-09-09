import Foundation

/// Everything the panel lets you change, in one value.
///
/// Kept together so the panel reads one thing and the pipeline is built from one thing — and so
/// adding a setting is one field rather than a new plumbing path.
public struct FCPCaptionSettings: Codable, Sendable, Equatable {
    public var model: WhisperModel
    public var engine: WhisperKitEngine.Options
    /// BCP-47 code, or `nil` to let the engine detect it.
    public var language: String?
    public var captions: CaptionSplitOptions

    public init(
        model: WhisperModel = .default,
        engine: WhisperKitEngine.Options = .init(),
        language: String? = "ko",
        captions: CaptionSplitOptions = .default
    ) {
        self.model = model
        self.engine = engine
        self.language = language
        self.captions = captions
    }

    public static let `default` = FCPCaptionSettings()
}

/// Reads and writes the settings. `UserDefaults` per spec §6 — no API key lives here, so there is
/// nothing in it the Keychain should be holding.
public final class SettingsStore: @unchecked Sendable {
    private static let key = "settings"
    private let defaults: UserDefaults

    public static let shared = SettingsStore()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Falls back to the defaults when nothing is stored **or when what is stored no longer
    /// decodes** — a settings file from an older build must not stop the panel from opening.
    public func load() -> FCPCaptionSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(FCPCaptionSettings.self, from: data)
        else { return .default }
        return settings
    }

    public func save(_ settings: FCPCaptionSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}
