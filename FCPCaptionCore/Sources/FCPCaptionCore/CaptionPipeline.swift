import AVFoundation
import Foundation

/// The whole job, once: FCPXML in, the same FCPXML with Korean captions on a clip out.
///
/// This is the piece the Workflow Extension panel will drive; the CLI drives it today. Keeping it
/// here — not in the UI — is what lets the caption path be tested and used before the extension
/// exists.
public struct CaptionPipeline: Sendable {
    /// What the caller shows while this runs. Fractions are of the whole job, not of the stage.
    public enum Stage: Sendable, Equatable {
        case readingDocument
        case extractingAudio
        case transcribing
        case buildingCaptions
        case writingDocument

        public var korean: String {
            switch self {
            case .readingDocument: "클립 정보를 읽는 중"
            case .extractingAudio: "오디오를 추출하는 중"
            case .transcribing: "음성을 전사하는 중"
            case .buildingCaptions: "자막을 만드는 중"
            case .writingDocument: "Final Cut Pro 문서를 쓰는 중"
            }
        }
    }

    public struct Result: Sendable {
        public var document: Data
        /// One entry per clip captioned, in timeline order.
        public var clips: [ClipResult]

        public var captions: [Caption] { clips.flatMap(\.captions) }
        public var words: Int { clips.reduce(0) { $0 + $1.words } }
        /// Captions that could not be placed because the editor's own captions already held that
        /// time. Reported, never silently dropped.
        public var skipped: Int { clips.reduce(0) { $0 + $1.skipped } }
    }

    public struct ClipResult: Sendable {
        public var clip: ClipRef
        public var captions: [Caption]
        public var words: Int
        public var skipped: Int
    }

    public var engine: any TranscriptionEngine
    public var captionOptions: CaptionSplitOptions
    public var language: String?

    public init(
        engine: any TranscriptionEngine,
        captionOptions: CaptionSplitOptions = .default,
        language: String? = "ko"
    ) {
        self.engine = engine
        self.captionOptions = captionOptions
        self.language = language
    }

    /// Transcription dominates the wall clock, so it owns most of the progress bar.
    private static let weights: [(Stage, ClosedRange<Double>)] = [
        (.readingDocument, 0...0.02),
        (.extractingAudio, 0.02...0.12),
        (.transcribing, 0.12...0.95),
        (.buildingCaptions, 0.95...0.97),
        (.writingDocument, 0.97...1.0),
    ]

    private static func overall(_ stage: Stage, _ fraction: Double) -> Double {
        guard let range = weights.first(where: { $0.0 == stage })?.1 else { return fraction }
        return range.lowerBound + (range.upperBound - range.lowerBound) * min(1, max(0, fraction))
    }

    /// Captions every audible clip in the document, or just `selected` when one is given.
    ///
    /// Dragging a project hands over its whole timeline, and someone who drags a project wants
    /// their project captioned — not its first clip. Progress is weighted by clip duration, so a
    /// 20-second clip before an 18-minute one does not take half the bar.
    public func run(
        document data: Data,
        clip selected: ClipRef? = nil,
        progress: @escaping @Sendable (Stage, Double) -> Void = { _, _ in }
    ) async throws -> Result {
        progress(.readingDocument, Self.overall(.readingDocument, 0))
        let parsed = try FCPXMLReader().read(data: data)
        let clips = try selected.map { [$0] } ?? audibleClips(in: parsed)

        let totalDuration = clips.reduce(0.0) { $0 + $1.durationSeconds }
        var elapsedDuration = 0.0
        var document = data
        var results: [ClipResult] = []

        for clip in clips {
            let share = totalDuration > 0 ? clip.durationSeconds / totalDuration : 1
            let base = totalDuration > 0 ? elapsedDuration / totalDuration : 0
            let scaled: @Sendable (Stage, Double) -> Void = { stage, fraction in
                progress(stage, Self.overall(stage, base + share * fraction))
            }

            let result = try await caption(clip: clip, in: &document, progress: scaled)
            results.append(result)
            elapsedDuration += clip.durationSeconds
        }

        // Silence on one clip of several is normal — a b-roll shot with no dialogue. Silence on
        // everything is worth saying out loud.
        guard results.contains(where: { !$0.captions.isEmpty }) else {
            throw CaptionPipelineError.noSpeechFound
        }
        progress(.writingDocument, 1)
        return Result(document: document, clips: results)
    }

    private func caption(
        clip: ClipRef,
        in document: inout Data,
        progress: @escaping @Sendable (Stage, Double) -> Void
    ) async throws -> ClipResult {
        // Sandboxed, the path alone is not enough; the bookmark FCP ships is the grant.
        let access = try MediaAccess(clip: clip)
        let media = access.url

        let audio = AudioExtractor.temporaryOutputURL()
        defer { try? FileManager.default.removeItem(at: audio) }

        // Only the part of the media the clip actually uses — captioning trimmed-away footage
        // would put captions where nothing is said.
        let range = CMTimeRange(
            start: CMTime(seconds: clip.start.seconds, preferredTimescale: 600),
            duration: CMTime(seconds: clip.duration.seconds, preferredTimescale: 600)
        )
        progress(.extractingAudio, 0)
        try await AudioExtractor().extract(from: media, range: range, to: audio) { fraction in
            progress(.extractingAudio, fraction)
        }
        try Task.checkCancellation()

        progress(.transcribing, 0)
        let words = try await engine.transcribe(audio: audio, language: language) { fraction in
            progress(.transcribing, fraction)
        }
        try Task.checkCancellation()

        progress(.buildingCaptions, 0)
        let captions = CaptionBuilder(options: captionOptions).build(from: words)
        guard !captions.isEmpty else {
            return ClipResult(clip: clip, captions: [], words: words.count, skipped: 0)
        }

        progress(.writingDocument, 0)
        let written = try FCPXMLWriter(language: language ?? "ko")
            .write(captions, to: clip, inDocument: document)
        document = written.document
        return ClipResult(clip: clip, captions: captions, words: words.count, skipped: written.skipped)
    }

    /// Every clip with audio, in the order the document lists them.
    private func audibleClips(in document: FCPXMLDocument) throws -> [ClipRef] {
        let audible = document.clips.filter(\.hasAudio)
        guard !audible.isEmpty else {
            throw document.clips.isEmpty ? CaptionPipelineError.noClips : CaptionPipelineError.noAudibleClip
        }
        return audible
    }
}

public enum CaptionPipelineError: LocalizedError, Equatable {
    case noClips
    case noAudibleClip
    case noMediaURL(String)
    case mediaMissing(URL)
    case noSpeechFound

    public var errorDescription: String? {
        switch self {
        case .noClips:
            "FCPXML에서 클립을 찾지 못했습니다."
        case .noAudibleClip:
            "오디오가 있는 클립이 없습니다."
        case let .noMediaURL(name):
            "클립의 원본 미디어 경로를 찾지 못했습니다: \(name)"
        case let .mediaMissing(url):
            "원본 미디어 파일을 찾을 수 없습니다: \(url.path(percentEncoded: false))"
        case .noSpeechFound:
            "음성을 찾지 못했습니다. 클립에 말소리가 있는지 확인해 주세요."
        }
    }
}
