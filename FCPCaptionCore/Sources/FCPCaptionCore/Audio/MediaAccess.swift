import Foundation
import os

/// Opens the original media a clip refers to, from inside a sandbox.
///
/// A workflow extension runs sandboxed, so a path like `/Users/…/Downloads/clip.MOV` is unreadable
/// even though the file is plainly there and the user can see it in Finder. Final Cut Pro solves
/// this by shipping a **security-scoped bookmark** inside every `media-rep`; resolving it is what
/// turns the path into something openable.
///
/// Outside a sandbox — the CLI — the plain path works and the bookmark is never needed, which is
/// exactly why this was missed until the panel ran for real.
public struct MediaAccess: ~Copyable {
    private static let log = Logger(subsystem: "com.jkh911208.FCPCaption", category: "media")

    public let url: URL
    private let scoped: Bool

    /// Resolves the media for `clip`, preferring whatever actually opens.
    ///
    /// - Throws: `CaptionPipelineError.mediaMissing` when neither the bookmark nor the path works,
    ///   naming the file — never a bare "permission denied".
    public init(clip: ClipRef) throws {
        if let bookmark = clip.mediaBookmark {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), resolved.startAccessingSecurityScopedResource() {
                if stale { Self.log.notice("security-scoped bookmark was stale but resolved") }
                self.url = resolved
                self.scoped = true
                return
            }
            Self.log.error("could not resolve the security-scoped bookmark; falling back to the path")
        }

        guard let url = clip.mediaURL else { throw CaptionPipelineError.noMediaURL(clip.name) }
        guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else {
            throw CaptionPipelineError.mediaMissing(url)
        }
        self.url = url
        self.scoped = false
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}
