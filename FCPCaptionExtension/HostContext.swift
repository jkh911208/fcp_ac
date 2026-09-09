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

    /// Key-value coding on `AnyObject`, so it works on a proxy.
    ///
    /// The release notes call these "proxy objects", and a proxy need not be an `NSObject`
    /// subclass — `as? NSObject` on one silently fails and takes everything after it with it,
    /// which is how the first version of this returned nothing at all.
    private static func value(_ key: String, of object: AnyObject?) -> AnyObject? {
        guard let object else { return nil }
        return (object as AnyObject).value(forKey: key) as AnyObject?
    }

    /// Walks up from the active sequence to its event and library.
    static func current() -> FCPXMLContainer {
        let host = ProExtensionHostSingleton() as AnyObject?
        guard let timeline = value("timeline", of: host),
              let sequence = value("activeSequence", of: timeline)
        else {
            log.notice("no active sequence; the project will not be wrapped")
            return FCPXMLContainer()
        }

        var container = FCPXMLContainer()
        var node = value("container", of: sequence)
        var depth = 0
        while let current = node, depth < 8 {
            depth += 1
            let type = (value("objectType", of: current) as? NSNumber)
                .map(\.intValue)
                .flatMap(ObjectType.init)
            switch type {
            case .event:
                container.eventName = value("name", of: current) as? String
                container.eventUID = value("UID", of: current) as? String
            case .library:
                container.libraryURL = value("url", of: current) as? URL
            default:
                break
            }
            node = value("container", of: current)
        }

        log.notice("""
            container: event=\(container.eventName ?? "none", privacy: .public) \
            library=\(container.libraryURL?.lastPathComponent ?? "none", privacy: .public)
            """)
        return container
    }
}
