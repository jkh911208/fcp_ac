import Foundation

/// What we need out of an FCPXML document — the clip to transcribe, and the timing grid to write
/// captions back onto.
public struct FCPXMLDocument: Sendable, Equatable {
    /// The version string as the document declared it. Echoed back on write, never hardcoded:
    /// the document FCP hands us is the authority on which schema it speaks.
    public var version: String
    public var sequence: SequenceInfo?
    public var clips: [ClipRef]

    public init(version: String, sequence: SequenceInfo?, clips: [ClipRef]) {
        self.version = version
        self.sequence = sequence
        self.clips = clips
    }

    /// The frame grid captions must land on. The *sequence's* format, not the asset's — a 60p clip
    /// conformed into a 59.94 timeline is captioned at 59.94.
    public var frameDuration: FCPTime? {
        sequence?.frameDuration ?? clips.first?.assetFrameDuration
    }
}

public struct SequenceInfo: Sendable, Equatable {
    public var projectName: String?
    public var eventName: String?
    public var formatID: String
    public var frameDuration: FCPTime
    public var duration: FCPTime
    public var tcStart: FCPTime

    public init(
        projectName: String?,
        eventName: String?,
        formatID: String,
        frameDuration: FCPTime,
        duration: FCPTime,
        tcStart: FCPTime
    ) {
        self.projectName = projectName
        self.eventName = eventName
        self.formatID = formatID
        self.frameDuration = frameDuration
        self.duration = duration
        self.tcStart = tcStart
    }
}

/// One clip on the spine, with everything needed to pull its audio and to place captions on it.
public struct ClipRef: Sendable, Equatable {
    /// The element name it came from (`asset-clip`, `clip`, …), so the writer can find it again.
    public var element: String
    /// The `ref` attribute — the resource id of the asset it plays.
    public var assetID: String
    public var name: String
    /// Where the clip sits on the parent timeline.
    public var offset: FCPTime
    /// Where playback starts *inside* the media. Caption offsets are relative to this, not to 0.
    public var start: FCPTime
    public var duration: FCPTime
    public var lane: Int?
    /// The original media on disk, from the asset's `media-rep`.
    public var mediaURL: URL?
    /// The security-scoped bookmark Final Cut Pro puts inside `media-rep`.
    ///
    /// This is not decoration. A workflow extension is sandboxed, so the media path alone is
    /// unreadable — `/Users/…/Downloads/clip.MOV` exists and still cannot be opened. The bookmark
    /// is the grant that makes it readable, which is why FCP ships one with every asset.
    public var mediaBookmark: Data?
    /// The asset's own format, which may differ from the sequence's (conformed clips).
    public var assetFrameDuration: FCPTime?
    public var hasAudio: Bool
    /// Captions already attached to this clip — the editor's, or ours from an earlier run.
    public var captions: [CaptionRef]

    public init(
        element: String,
        assetID: String,
        name: String,
        offset: FCPTime,
        start: FCPTime,
        duration: FCPTime,
        lane: Int? = nil,
        mediaURL: URL? = nil,
        mediaBookmark: Data? = nil,
        assetFrameDuration: FCPTime? = nil,
        hasAudio: Bool = true,
        captions: [CaptionRef] = []
    ) {
        self.element = element
        self.assetID = assetID
        self.name = name
        self.offset = offset
        self.start = start
        self.duration = duration
        self.lane = lane
        self.mediaURL = mediaURL
        self.mediaBookmark = mediaBookmark
        self.assetFrameDuration = assetFrameDuration
        self.hasAudio = hasAudio
        self.captions = captions
    }

    public var durationSeconds: TimeInterval { duration.seconds }
}

/// A `<caption>` element as it stands in the document.
public struct CaptionRef: Sendable, Equatable {
    public var role: String
    public var lane: Int?
    /// Position in the parent clip's media time — comparable to `ClipRef.start`, not to zero.
    public var offset: FCPTime
    /// The caption's own internal time base (Final Cut Pro writes ~1 hour here).
    public var start: FCPTime
    public var duration: FCPTime
    public var name: String?
    /// All text runs joined, trailing newlines trimmed. FCP splits a line break into its own run.
    public var text: String

    public init(
        role: String,
        lane: Int?,
        offset: FCPTime,
        start: FCPTime,
        duration: FCPTime,
        name: String?,
        text: String
    ) {
        self.role = role
        self.lane = lane
        self.offset = offset
        self.start = start
        self.duration = duration
        self.name = name
        self.text = text
    }

    /// The language subtag in a caption role like `iTT?captionFormat=ITT.ko`, when there is one.
    public var language: String? {
        guard let range = role.range(of: "captionFormat=ITT.") else { return nil }
        let value = role[range.upperBound...]
        return value.isEmpty ? nil : String(value)
    }
}
