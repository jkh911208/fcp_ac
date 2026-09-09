import Foundation
import FCPCaptionCore
import UniformTypeIdentifiers

/// What Final Cut Pro puts on the pasteboard when a clip is dragged out of the timeline.
///
/// The UTIs are read from Final Cut Pro's own `Info.plist`, not guessed:
/// `com.apple.FinalCutPro.xml` for a `.fcpxml` and `com.apple.finalcutpro.xmld` for the bundle
/// form. A drag may also arrive as a plain file URL.
///
/// **Unverified until the panel receives its first real drop:** whether FCP puts the FCPXML on the
/// pasteboard as data, as a file URL, or both. `DroppedDocument.parse` accepts either, and the
/// panel logs the types it actually saw so the answer replaces this comment rather than a guess.
public enum DroppedDocument {
    public static let fcpxmlType = UTType("com.apple.FinalCutPro.xml") ?? .xml
    public static let fcpxmlBundleType = UTType("com.apple.finalcutpro.xmld") ?? .xml

    public static var acceptedTypes: [UTType] {
        [fcpxmlType, fcpxmlBundleType, .fileURL, .xml]
    }

    /// Reads FCPXML from a dropped file, following the `.fcpxmld` bundle to its payload.
    public static func data(atFile url: URL) throws -> Data {
        var target = url
        if url.pathExtension.lowercased() == "fcpxmld" {
            target = url.appending(path: "Info.fcpxml")
        }
        return try Data(contentsOf: target)
    }

    /// Parses dropped bytes and picks the clip to caption.
    ///
    /// Returns the document alongside the clip because the writer needs the original bytes back —
    /// captions are added to the document FCP gave us, not to one we rebuild.
    public static func parse(_ data: Data) throws -> (document: Data, clips: [ClipRef], parsed: FCPXMLDocument) {
        let parsed = try FCPXMLReader().read(data: data)
        guard !parsed.clips.isEmpty else { throw CaptionPipelineError.noClips }
        return (data, parsed.clips.filter(\.hasAudio), parsed)
    }
}
