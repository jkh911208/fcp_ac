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

    /// Where the walk writes what it saw.
    ///
    /// `os_log` from this extension does not reach `log show` — several attempts produced nothing
    /// at all — and a silent failure here looks exactly like a working feature until someone
    /// checks the library. A file in our own container is crude and it is legible.
    private static var traceURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "FCPCaption", directoryHint: .isDirectory)
            .appending(path: "host-trace.txt")
    }

    /// Serial, so entries keep their order without holding up whoever wrote them.
    private static let traceQueue = DispatchQueue(label: "com.jkh911208.FCPCaption.host-trace")

    private static func trace(_ lines: [String]) {
        guard let traceURL else { return }
        let stamp = ISO8601DateFormatter().string(from: .now)
        let text = ([stamp] + lines).joined(separator: "\n") + "\n\n"
        // Off the calling thread: this reads and rewrites the whole file, and the caller is
        // usually the main thread in the middle of something the user can feel.
        traceQueue.async {
            try? FileManager.default.createDirectory(
                at: traceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Bounded: this is written every time the panel appears, and a diagnostic that fills a
            // disk is not a diagnostic.
            let existing = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
            let combined = existing.count > 32_768
                ? String(existing.suffix(16_384)) + text
                : existing + text
            try? Data(combined.utf8).write(to: traceURL, options: .atomic)
        }
    }

    /// The last answer worth keeping.
    ///
    /// `activeSequence` comes back nil while the panel has focus — which is exactly when the user
    /// presses the button — so asking only then gets nothing. Asking at every moment the panel
    /// hears about and keeping the first real answer catches the one that counts: the drop, when
    /// Final Cut Pro is frontmost because the user is dragging out of it.
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var value = FCPXMLContainer()

        func store(_ container: FCPXMLContainer) {
            lock.withLock { if container.isUsable { value = container } }
        }

        var current: FCPXMLContainer { lock.withLock { value } }
    }

    /// Asks the host, remembering a usable answer. Safe to call often.
    @discardableResult
    static func refresh() -> FCPXMLContainer {
        let container = read()
        cache.store(container)
        return container.isUsable ? container : cache.current
    }

    /// The best answer so far, asking once more first.
    static func current() -> FCPXMLContainer { refresh() }

    /// Registered with the timeline before it is read.
    ///
    /// `activeSequence` came back nil at every moment — panel load, drag, drop, generate — while
    /// the host and the timeline proxy themselves resolved fine. Apple's own flow registers an
    /// observer before reading, so the proxy may only be populated for someone who is watching.
    ///
    /// Deliberately **not** declared as conforming to `FCPXTimelineObserver`: Objective-C
    /// protocols are duck-typed at run time, the host only needs the selectors to exist, and
    /// declaring conformance would drag in a protocol symbol from a framework the release notes
    /// say not to link.
    private final class Watcher: NSObject {
        @objc func activeSequenceChanged() { HostContext.refresh() }
        @objc func playheadTimeChanged() {}
        @objc func sequenceTimeRangeChanged() {}
    }

    private static let watcher = Watcher()
    private static let registered = Locked(false)

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
    }

    /// Adds our observer once. Sent dynamically — `FCPXTimeline` is a class we must not link.
    private static func observe(_ timeline: AnyObject) -> String {
        registered.withLock { done in
            guard !done else { return "already registered" }
            let selector = Selector(("addTimelineObserver:"))
            guard timeline.responds(to: selector) else { return "timeline does not respond to addTimelineObserver:" }
            _ = (timeline as AnyObject).perform(selector, with: watcher)
            done = true
            return "registered observer"
        }
    }

    /// Walks up from the active sequence to its event and library.
    ///
    /// **Every property read here is a synchronous call into Final Cut Pro**, so this is slow in
    /// proportion to how much it finds: a walk that resolves a sequence, its event and its library
    /// measured about two seconds, while one that finds no sequence returns almost at once. That
    /// asymmetry is why the elapsed time is recorded — a caller that blocks the main thread for
    /// two seconds is a bug waiting to be reintroduced, and it should be visible when it is.
    private static func read() -> FCPXMLContainer {
        let started = DispatchTime.now()
        var notes: [String] = []
        let host = ProExtensionHostSingleton() as AnyObject?
        notes.append("host: \(host.map { String(describing: type(of: $0)) } ?? "nil")")
        if let host {
            notes.append("responds to timeline: \(host.responds(to: Selector(("timeline"))))")
        }

        let timeline = value("timeline", of: host)
        notes.append("timeline: \(timeline.map { String(describing: type(of: $0)) } ?? "nil")")
        if let timeline { notes.append(observe(timeline)) }
        let sequence = value("activeSequence", of: timeline)
        notes.append("activeSequence: \(sequence.map { String(describing: type(of: $0)) } ?? "nil")")
        if let sequence {
            notes.append("sequence name: \(value("name", of: sequence) as? String ?? "nil")")
        }

        guard let sequence else {
            // Almost always the automation permission. The host interface talks to Final Cut Pro
            // over Apple Events, and until the user allows that in System Settings the properties
            // simply come back nil — no error, no exception, nothing in any log.
            trace(notes + [
                "-> no active sequence; likely the automation permission is not granted",
                elapsed(since: started),
            ])
            return FCPXMLContainer()
        }

        var container = FCPXMLContainer()
        var node = value("container", of: sequence)
        var depth = 0
        while let current = node, depth < 8 {
            depth += 1
            let objectType = (value("objectType", of: current) as? NSNumber)
                .map(\.intValue)
                .flatMap(ObjectType.init)
            switch objectType {
            case .event:
                container.eventName = value("name", of: current) as? String
                container.eventUID = value("UID", of: current) as? String
            case .library:
                container.libraryURL = value("url", of: current) as? URL
            default:
                break
            }
            notes.append("step \(depth): objectType=\(String(describing: objectType)) class=\(String(describing: Swift.type(of: current)))")
            node = value("container", of: current)
        }

        notes.append("-> event=\(container.eventName ?? "none") uid=\(container.eventUID ?? "none") library=\(container.libraryURL?.lastPathComponent ?? "none")")
        trace(notes + [elapsed(since: started)])
        return container
    }

    private static func elapsed(since started: DispatchTime) -> String {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        return String(format: "took %.0f ms on %@", ms, Thread.isMainThread ? "the main thread" : "a background thread")
    }
}
