import Foundation
import FCPCaptionCore
import Observation

/// The panel's state machine. Everything the view shows comes from `state`; the view itself makes
/// no decisions.
///
/// Deliberately free of AppKit and of the ProExtension SDK so it compiles, previews and tests
/// without Final Cut Pro or the extension target.
@MainActor
@Observable
public final class PanelModel {
    public enum State: Equatable {
        /// Nothing dropped yet. The only state that shows the drop target.
        case waiting
        case reading
        /// Every audible clip in the dropped document — a project drop carries the whole timeline,
        /// and all of it gets captioned.
        ///
        /// `hasTimeline` is false when the drop was a browser *clip* rather than a project: there
        /// is no sequence in the document, so captions can only attach to the library clip and
        /// will not appear on any timeline the clip was already edited into.
        case ready(clips: [ClipRef], hasTimeline: Bool)
        case working(CaptionPipeline.Report)
        case finished(Finished)
        case failed(message: String, canRetry: Bool)
    }

    public struct Finished: Equatable {
        public var captionCount: Int
        public var clipName: String
        public var clipCount: Int
        public var output: URL
        /// The iTT caption file for the whole timeline, when the document had a frame rate.
        ///
        /// This is the one that lands on the project already open — Final Cut Pro's caption import
        /// adds to the current timeline instead of bringing a new event and project into the
        /// library, which is what importing FCPXML does.
        public var captionFile: String?
        public var captionFileName: String
        /// Captions the editor's own captions were already occupying. Shown when non-zero, because
        /// a caption missing from the timeline with no explanation reads as a bug.
        public var skipped: Int

        public init(
            captionCount: Int,
            clipName: String,
            output: URL,
            skipped: Int = 0,
            clipCount: Int = 1,
            captionFile: String? = nil,
            captionFileName: String = "자막.itt"
        ) {
            self.captionCount = captionCount
            self.clipName = clipName
            self.clipCount = clipCount
            self.captionFile = captionFile
            self.captionFileName = captionFileName
            self.output = output
            self.skipped = skipped
        }
    }

    public private(set) var state: State = .waiting
    /// The engine label shown under the clip, e.g. "이 Mac에서 · large-v3-turbo".
    public var engineLabel: String
    /// Saved on every change, so closing the panel mid-edit does not lose the setting.
    public var settings: FCPCaptionSettings {
        didSet {
            guard settings != oldValue else { return }
            store?.save(settings)
            engineLabel = Self.label(for: settings)
        }
    }
    public var showsSettings = false

    private var document: Data?
    private var clips: [ClipRef] = []
    private var hasTimeline = false
    private var task: Task<Void, Never>?

    private let makePipeline: @Sendable (FCPCaptionSettings) -> CaptionPipeline
    private let deliver: @Sendable (Data, ClipRef) throws -> URL
    private let store: SettingsStore?

    public static func label(for settings: FCPCaptionSettings) -> String {
        "이 Mac에서 · \(settings.model.displayName)"
    }

    /// - Parameters:
    ///   - makePipeline: builds the pipeline per run, so a cancelled engine is never reused.
    ///   - deliver: writes the captioned document somewhere Final Cut Pro can open it, and
    ///     returns where it went. Injected because "somewhere" is a policy the extension and the
    ///     tests answer differently.
    public init(
        engineLabel: String,
        makePipeline: @escaping @Sendable (FCPCaptionSettings) -> CaptionPipeline,
        deliver: @escaping @Sendable (Data, ClipRef) throws -> URL,
        store: SettingsStore? = nil,
        settings: FCPCaptionSettings = .default
    ) {
        self.engineLabel = engineLabel
        self.makePipeline = makePipeline
        self.deliver = deliver
        self.store = store
        self.settings = store?.load() ?? settings
        self.engineLabel = Self.label(for: self.settings)
    }

    // MARK: - Input

    public func receive(_ data: Data) {
        state = .reading
        do {
            let (document, clips, parsed) = try DroppedDocument.parse(data)
            guard !clips.isEmpty else { throw CaptionPipelineError.noAudibleClip }
            self.document = document
            self.clips = clips
            self.hasTimeline = parsed.sequence != nil
            state = .ready(clips: clips, hasTimeline: hasTimeline)
        } catch {
            fail(error, canRetry: false)
        }
    }

    public func receive(fileAt url: URL) {
        state = .reading
        do {
            receive(try DroppedDocument.data(atFile: url))
        } catch {
            fail(error, canRetry: false)
        }
    }

    // MARK: - Run

    public func start() {
        guard let document, !clips.isEmpty, task == nil else { return }
        state = .working(CaptionPipeline.Report(stage: .readingDocument, fraction: 0))

        let settings = self.settings
        task = Task { [makePipeline, deliver] in
            defer { self.task = nil }
            do {
                // No `clip:` — the pipeline captions every audible clip the document carries.
                let result = try await makePipeline(settings).run(document: document) { report in
                    Task { @MainActor in self.advance(report) }
                }
                try Task.checkCancellation()
                let first = result.clips.first?.clip
                let output = try deliver(result.document, first ?? self.clips[0])
                self.state = .finished(Finished(
                    captionCount: result.captions.count - result.skipped,
                    clipName: first?.name ?? "",
                    output: output,
                    skipped: result.skipped,
                    clipCount: result.clips.count,
                    captionFile: result.captionFile(language: settings.language ?? "ko"),
                    captionFileName: "\(first?.name ?? "자막").itt"
                ))
            } catch is CancellationError {
                // Cancelling returns to the clip you dropped, not to an empty panel: the next
                // thing a person does after cancelling is almost always run it again.
                self.state = self.clips.isEmpty
                    ? .waiting
                    : .ready(clips: self.clips, hasTimeline: self.hasTimeline)
            } catch {
                self.fail(error, canRetry: true)
            }
        }
    }

    public func cancel() {
        task?.cancel()
    }

    /// Back to the drop target, forgetting the clip.
    public func reset() {
        task?.cancel()
        document = nil
        clips = []
        state = .waiting
    }

    /// Retry after a failure, keeping the clip that was already dropped.
    public func retry() {
        guard !clips.isEmpty else { return reset() }
        start()
    }

    /// Puts the model in a given state for rendering previews. Not part of the panel's behaviour.
    public func setStateForPreview(_ state: State) {
        self.state = state
    }

    // MARK: - Internals

    /// Progress can arrive after cancellation or completion; only a running job may repaint.
    private func advance(_ report: CaptionPipeline.Report) {
        guard case .working = state else { return }
        state = .working(report)
    }

    private func fail(_ error: any Error, canRetry: Bool) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        state = .failed(message: message, canRetry: canRetry)
    }
}
