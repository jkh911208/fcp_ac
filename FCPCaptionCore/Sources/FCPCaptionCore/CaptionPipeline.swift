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
        public var captions: [Caption]
        public var clip: ClipRef
        public var words: Int
        /// Captions that could not be placed because the editor's own captions already held that
        /// time. Reported, never silently dropped.
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

    public func run(
        document data: Data,
        clip selected: ClipRef? = nil,
        progress: @escaping @Sendable (Stage, Double) -> Void = { _, _ in }
    ) async throws -> Result {
        progress(.readingDocument, Self.overall(.readingDocument, 0))
        let parsed = try FCPXMLReader().read(data: data)

        let clip = try selected ?? pickClip(in: parsed)
        guard let media = clip.mediaURL else { throw CaptionPipelineError.noMediaURL(clip.name) }
        guard FileManager.default.isReadableFile(atPath: media.path(percentEncoded: false)) else {
            throw CaptionPipelineError.mediaMissing(media)
        }

        let audio = AudioExtractor.temporaryOutputURL()
        defer { try? FileManager.default.removeItem(at: audio) }

        // Only the part of the media the clip actually uses — captioning trimmed-away footage
        // would put captions where nothing is said.
        let range = CMTimeRange(
            start: CMTime(seconds: clip.start.seconds, preferredTimescale: 600),
            duration: CMTime(seconds: clip.duration.seconds, preferredTimescale: 600)
        )
        progress(.extractingAudio, Self.overall(.extractingAudio, 0))
        try await AudioExtractor().extract(from: media, range: range, to: audio) { fraction in
            progress(.extractingAudio, Self.overall(.extractingAudio, fraction))
        }
        try Task.checkCancellation()

        progress(.transcribing, Self.overall(.transcribing, 0))
        let words = try await engine.transcribe(audio: audio, language: language) { fraction in
            progress(.transcribing, Self.overall(.transcribing, fraction))
        }
        try Task.checkCancellation()

        progress(.buildingCaptions, Self.overall(.buildingCaptions, 0))
        let captions = CaptionBuilder(options: captionOptions).build(from: words)
        guard !captions.isEmpty else { throw CaptionPipelineError.noSpeechFound }

        progress(.writingDocument, Self.overall(.writingDocument, 0))
        let written = try FCPXMLWriter(language: language ?? "ko")
            .write(captions, to: clip, inDocument: data)
        progress(.writingDocument, 1)

        return Result(
            document: written.document,
            captions: captions,
            clip: clip,
            words: words.count,
            skipped: written.skipped
        )
    }

    /// The clip to caption: the first one with audio. With several, the caller picks — silently
    /// captioning an arbitrary clip of many would be a guess about intent.
    private func pickClip(in document: FCPXMLDocument) throws -> ClipRef {
        let audible = document.clips.filter(\.hasAudio)
        guard let first = audible.first else {
            throw document.clips.isEmpty ? CaptionPipelineError.noClips : CaptionPipelineError.noAudibleClip
        }
        return first
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
