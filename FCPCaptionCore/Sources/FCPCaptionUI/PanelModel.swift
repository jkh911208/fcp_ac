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
        case ready(ClipRef)
        case working(stage: CaptionPipeline.Stage, fraction: Double)
        case finished(Finished)
        case failed(message: String, canRetry: Bool)
    }

    public struct Finished: Equatable {
        public var captionCount: Int
        public var clipName: String
        public var output: URL
        /// Captions the editor's own captions were already occupying. Shown when non-zero, because
        /// a caption missing from the timeline with no explanation reads as a bug.
        public var skipped: Int

        public init(captionCount: Int, clipName: String, output: URL, skipped: Int = 0) {
            self.captionCount = captionCount
            self.clipName = clipName
            self.output = output
            self.skipped = skipped
        }
    }

    public private(set) var state: State = .waiting
    /// The engine label shown under the clip, e.g. "이 Mac에서 · large-v3-turbo".
    public var engineLabel: String

    private var document: Data?
    private var clip: ClipRef?
    private var task: Task<Void, Never>?

    private let makePipeline: @Sendable () -> CaptionPipeline
    private let deliver: @Sendable (Data, ClipRef) throws -> URL

    /// - Parameters:
    ///   - makePipeline: builds the pipeline per run, so a cancelled engine is never reused.
    ///   - deliver: writes the captioned document somewhere Final Cut Pro can open it, and
    ///     returns where it went. Injected because "somewhere" is a policy the extension and the
    ///     tests answer differently.
    public init(
        engineLabel: String,
        makePipeline: @escaping @Sendable () -> CaptionPipeline,
        deliver: @escaping @Sendable (Data, ClipRef) throws -> URL
    ) {
        self.engineLabel = engineLabel
        self.makePipeline = makePipeline
        self.deliver = deliver
    }

    // MARK: - Input

    public func receive(_ data: Data) {
        state = .reading
        do {
            let (document, clips, _) = try DroppedDocument.parse(data)
            guard let clip = clips.first else { throw CaptionPipelineError.noAudibleClip }
            self.document = document
            self.clip = clip
            state = .ready(clip)
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
        guard let document, let clip, task == nil else { return }
        state = .working(stage: .readingDocument, fraction: 0)

        task = Task { [makePipeline, deliver] in
            defer { self.task = nil }
            do {
                let result = try await makePipeline().run(document: document, clip: clip) { stage, fraction in
                    Task { @MainActor in self.advance(stage: stage, fraction: fraction) }
                }
                try Task.checkCancellation()
                let output = try deliver(result.document, result.clip)
                self.state = .finished(Finished(
                    captionCount: result.captions.count - result.skipped,
                    clipName: result.clip.name,
                    output: output,
                    skipped: result.skipped
                ))
            } catch is CancellationError {
                // Cancelling returns to the clip you dropped, not to an empty panel: the next
                // thing a person does after cancelling is almost always run it again.
                self.state = self.clip.map { State.ready($0) } ?? .waiting
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
        clip = nil
        state = .waiting
    }

    /// Retry after a failure, keeping the clip that was already dropped.
    public func retry() {
        guard clip != nil else { return reset() }
        start()
    }

    /// Puts the model in a given state for rendering previews. Not part of the panel's behaviour.
    public func setStateForPreview(_ state: State) {
        self.state = state
    }

    // MARK: - Internals

    /// Progress can arrive after cancellation or completion; only a running job may repaint.
    private func advance(stage: CaptionPipeline.Stage, fraction: Double) {
        guard case .working = state else { return }
        state = .working(stage: stage, fraction: fraction)
    }

    private func fail(_ error: any Error, canRetry: Bool) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        state = .failed(message: message, canRetry: canRetry)
    }
}
