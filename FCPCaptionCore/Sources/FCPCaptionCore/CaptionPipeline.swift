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
        /// Fetching the model. Once per model per machine.
        case downloadingModel
        /// Loading it into CoreML and, the first time, compiling for the Neural Engine. Minutes,
        /// with nothing to report — see `isIndeterminate`.
        case loadingModel
        case transcribing
        case buildingCaptions
        case writingDocument

        /// Whether the fraction means anything. A CoreML load reports nothing at all, so the
        /// honest display there is a spinner, not a bar frozen at some number.
        public var isIndeterminate: Bool { self == .loadingModel }

        /// True for the two stages that only happen the first time a model is used — worth saying
        /// out loud, because otherwise every run looks like it might take ten minutes.
        public var isFirstRunOnly: Bool { self == .downloadingModel || self == .loadingModel }

        public var korean: String {
            switch self {
            case .readingDocument: "클립 정보를 읽는 중"
            case .extractingAudio: "오디오를 추출하는 중"
            case .downloadingModel: "음성 인식 모델 다운로드 중"
            case .loadingModel: "모델을 준비하는 중"
            case .transcribing: "음성을 전사하는 중"
            case .buildingCaptions: "자막을 만드는 중"
            case .writingDocument: "Final Cut Pro 문서를 쓰는 중"
            }
        }
    }

    /// What the panel draws. More than a fraction, because the stages differ in what they can
    /// honestly report.
    public struct Report: Sendable, Equatable {
        public var stage: Stage
        /// Overall, 0...1. Meaningless while `stage.isIndeterminate`.
        public var fraction: Double
        /// The second line — "1.2 GB / 3.0 GB · 24 MB/s", or the first-run note.
        public var detail: String?
        public var isIndeterminate: Bool { stage.isIndeterminate }

        public init(stage: Stage, fraction: Double, detail: String? = nil) {
            self.stage = stage
            self.fraction = fraction
            self.detail = detail
        }
    }

    public struct Result: Sendable {
        public var document: Data
        /// One entry per clip captioned, in timeline order.
        public var clips: [ClipResult]

        public var captions: [Caption] { clips.flatMap(\.captions) }
        /// The sequence's frame duration, needed to write a caption file's SMPTE timecodes.
        public var frameDuration: FCPTime?
        public var style: CaptionStyle = .default

        /// Captions positioned against the **timeline** rather than each clip, which is how a
        /// caption file is read. Final Cut Pro imports one of these straight onto the project that
        /// is already open — no new event, no new project, no dialog.
        public var timelineCaptions: [Caption] {
            clips.flatMap { result in
                result.captions.map { caption in
                    Caption(lines: caption.lines,
                            start: caption.start + result.clip.offset.seconds,
                            end: caption.end + result.clip.offset.seconds)
                }
            }
        }

        /// An iTT caption file for the whole timeline, or nil when the document had no frame rate.
        public func captionFile(language: String) -> String? {
            guard let frameDuration else { return nil }
            return ITTWriter(language: language, style: style)
                .string(from: timelineCaptions, frameDuration: frameDuration)
        }
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
    public var style: CaptionStyle
    /// Where the dropped project lives, when Final Cut Pro told us. Used to put the project back
    /// inside its own event so an import updates it instead of duplicating it.
    public var container: FCPXMLContainer

    public init(
        engine: any TranscriptionEngine,
        captionOptions: CaptionSplitOptions = .default,
        language: String? = "ko",
        style: CaptionStyle = .default,
        container: FCPXMLContainer = .init()
    ) {
        self.engine = engine
        self.captionOptions = captionOptions
        self.language = language
        self.style = style
        self.container = container
    }

    /// Transcription dominates the wall clock, so it owns most of the progress bar.
    private static let weights: [(Stage, ClosedRange<Double>)] = [
        (.readingDocument, 0...0.02),
        (.extractingAudio, 0.02...0.10),
        (.downloadingModel, 0.10...0.14),
        (.loadingModel, 0.14...0.18),
        (.transcribing, 0.18...0.95),
        (.buildingCaptions, 0.95...0.97),
        (.writingDocument, 0.97...1.0),
    ]

    /// Turns an engine phase into something the panel can draw, including the byte counts and the
    /// once-only note.
    public static func report(for phase: TranscriptionPhase, fraction: Double) -> Report {
        switch phase {
        case let .downloadingModel(downloaded, total, bytesPerSecond):
            let share = total > 0 ? Double(downloaded) / Double(total) : 0
            var detail = "\(gigabytes(downloaded)) / \(gigabytes(total))"
            if bytesPerSecond > 0 { detail += " · \(megabytesPerSecond(bytesPerSecond))" }
            detail += " · 이 모델을 처음 쓸 때 한 번만 받습니다"
            return Report(stage: .downloadingModel, fraction: share, detail: detail)
        case .loadingModel:
            return Report(stage: .loadingModel, fraction: 0,
                          detail: "이 모델을 처음 쓸 때만 몇 분 걸립니다. 다음부터는 바로 시작합니다.")
        case .transcribing:
            return Report(stage: .transcribing, fraction: fraction)
        }
    }

    public static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    public static func megabytesPerSecond(_ bytesPerSecond: Double) -> String {
        String(format: "%.0f MB/s", bytesPerSecond / 1_048_576)
    }

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
        progress: @escaping @Sendable (Report) -> Void = { _ in }
    ) async throws -> Result {
        progress(Report(stage: .readingDocument, fraction: Self.overall(.readingDocument, 0)))
        let parsed = try FCPXMLReader().read(data: data)
        let clips = try selected.map { [$0] } ?? audibleClips(in: parsed)

        let totalDuration = clips.reduce(0.0) { $0 + $1.durationSeconds }
        var elapsedDuration = 0.0
        var document = data
        var results: [ClipResult] = []

        for clip in clips {
            let share = totalDuration > 0 ? clip.durationSeconds / totalDuration : 1
            let base = totalDuration > 0 ? elapsedDuration / totalDuration : 0
            let scaled: @Sendable (Report) -> Void = { report in
                var report = report
                report.fraction = Self.overall(report.stage, base + share * report.fraction)
                progress(report)
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
        progress(Report(stage: .writingDocument, fraction: 1))
        var result = Result(document: try FCPXMLContainerWriter.wrapping(document, in: container),
                            clips: results)
        result.frameDuration = parsed.frameDuration
        result.style = style
        return result
    }

    private func caption(
        clip: ClipRef,
        in document: inout Data,
        progress: @escaping @Sendable (Report) -> Void
    ) async throws -> ClipResult {
        // Sandboxed, the path alone is not enough; the bookmark FCP ships is the grant.
        let access = try MediaAccess(clip: clip)
        let media = access.url

        let audio = AudioExtractor.temporaryOutputURL()
        defer { try? FileManager.default.removeItem(at: audio) }

        // Only the part of the media the clip actually uses — captioning trimmed-away footage
        // would put captions where nothing is said.
        let range = CMTimeRange(
            start: CMTime(seconds: clip.mediaStartSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: clip.duration.seconds, preferredTimescale: 600)
        )
        progress(Report(stage: .extractingAudio, fraction: 0))
        try await AudioExtractor().extract(from: media, range: range, to: audio) { fraction in
            progress(Report(stage: .extractingAudio, fraction: fraction))
        }
        try Task.checkCancellation()

        let words = try await engine.transcribe(audio: audio, language: language) { phase, fraction in
            progress(Self.report(for: phase, fraction: fraction))
        }
        try Task.checkCancellation()

        progress(Report(stage: .buildingCaptions, fraction: 0))
        let captions = CaptionBuilder(options: captionOptions).build(from: words)
        guard !captions.isEmpty else {
            return ClipResult(clip: clip, captions: [], words: words.count, skipped: 0)
        }

        progress(Report(stage: .writingDocument, fraction: 0))
        let written = try FCPXMLWriter(language: language ?? "ko", style: style)
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
