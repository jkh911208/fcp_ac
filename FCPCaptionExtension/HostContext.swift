import Foundation
import FCPCaptionCore
import os

/// Reads where the open project lives from Final Cut Pro's host interface.
///
/// The SDK release notes are explicit that an extension "does not have direct access to proxy
/// object class symbols or their class methods", so there is no `as? FCPXEvent` to be had — the
/// framework ships as headers with no binary. The documented way through is the `objectType` enum
/// plus key-value coding, which works on any `NSObject` without its class symbol.
enum HostContext {
    private static let log = Logger(subsystem: "com.jkh911208.FCPCaption", category: "host")

    // From FCPXHost.h.
    private enum ObjectType: Int {
        case library = 1, event = 2, project = 3, sequence = 4
    }

    /// Walks up from the active sequence to its event and library.
    static func current() -> FCPXMLContainer {
        guard let host = ProExtensionHostSingleton() as? NSObject,
              let timeline = host.value(forKey: "timeline") as? NSObject,
              let sequence = timeline.value(forKey: "activeSequence") as? NSObject
        else {
            log.notice("no active sequence; the project will not be wrapped")
            return FCPXMLContainer()
        }

        var container = FCPXMLContainer()
        var node: NSObject? = sequence.value(forKey: "container") as? NSObject
        var depth = 0
        while let current = node, depth < 8 {
            depth += 1
            let type = (current.value(forKey: "objectType") as? Int).flatMap(ObjectType.init)
            switch type {
            case .event:
                container.eventName = current.value(forKey: "name") as? String
                container.eventUID = current.value(forKey: "UID") as? String
            case .library:
                container.libraryURL = current.value(forKey: "url") as? URL
            default:
                break
            }
            node = current.value(forKey: "container") as? NSObject
        }

        log.notice("""
            container: event=\(container.eventName ?? "none", privacy: .public) \
            library=\(container.libraryURL?.lastPathComponent ?? "none", privacy: .public)
            """)
        return container
    }
}
