import AppKit
import FCPCaptionUI
import os
import UniformTypeIdentifiers

/// The panel's root view: a drop target with the SwiftUI panel inside it.
///
/// Final Cut Pro hands a dragged clip over as FCPXML. **Exactly how is unverified** — as pasteboard
/// data, as a file URL, under which type — so this accepts every plausible shape and logs the types
/// it actually saw, which is how the guess gets replaced by a fact on the first real drop.
final class CaptionDropView: NSView {
    private static let log = Logger(subsystem: "com.jkh911208.FCPCaption", category: "drop")

    var onDrop: ((Data) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    /// Version-specific types first, the way Apple's own sample orders them, then the generic one,
    /// then a dropped file for the export-and-drop case.
    private static let acceptedTypes: [NSPasteboard.PasteboardType] = {
        let identifiers = [
            "com.apple.finalcutpro.xml.v1-14",
            "com.apple.finalcutpro.xml.v1-13",
            "com.apple.finalcutpro.xml.v1-11",
            "com.apple.finalcutpro.xml.v1-10",
            "com.apple.finalcutpro.xml.v1-9",
            "com.apple.finalcutpro.xml",
            DroppedDocument.fcpxmlType.identifier,
            DroppedDocument.fcpxmlBundleType.identifier,
        ]
        var types = identifiers.map { NSPasteboard.PasteboardType($0) }
        types.append(.fileURL)
        return types
    }()

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Log every type on the pasteboard, once per drag. This is the only way to learn what FCP
        // actually sends, and it is a fact worth writing down rather than guessing at.
        let types = sender.draggingPasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
        Self.log.notice("drag entered with types: \(types, privacy: .public)")
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        for type in pasteboard.types ?? [] where type.rawValue.contains("finalcutpro") || type.rawValue.contains("FinalCutPro") {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                Self.log.notice("using pasteboard data of type \(type.rawValue, privacy: .public)")
                onDrop?(data)
                return true
            }
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first(where: { ["fcpxml", "fcpxmld"].contains($0.pathExtension.lowercased()) }) ?? urls.first {
            do {
                Self.log.notice("using dropped file \(url.lastPathComponent, privacy: .public)")
                onDrop?(try DroppedDocument.data(atFile: url))
                return true
            } catch {
                Self.log.error("could not read dropped file: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        Self.log.error("drop carried nothing we could read")
        return false
    }
}
