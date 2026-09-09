import Foundation

/// Where a project lives in the library, as Final Cut Pro reports it.
public struct FCPXMLContainer: Sendable, Equatable {
    public var libraryURL: URL?
    public var eventName: String?
    public var eventUID: String?

    public init(libraryURL: URL? = nil, eventName: String? = nil, eventUID: String? = nil) {
        self.libraryURL = libraryURL
        self.eventName = eventName
        self.eventUID = eventUID
    }

    public var isUsable: Bool { eventName != nil }
}

/// Puts a bare `<project>` back inside the event and library it came from.
///
/// Dragging a project out of the browser hands over the project alone — Apple's documentation says
/// as much, and the delivered document confirms it: no `<library>`, no `<event>`. Final Cut Pro
/// then has nowhere to put the project on import and invents an event for it, which is where
/// "9-9-26 1" and "9-9-26 2" came from.
///
/// The document exported from Final Cut Pro by hand *does* carry both, and importing that one made
/// FCP ask whether to replace the matching items instead of silently duplicating them. So the
/// wrapper is the difference between "a copy appears" and "you are asked, and Replace updates what
/// you were editing".
public enum FCPXMLContainerWriter {
    /// Wraps every top-level `project` in `container`'s event and library. A document that already
    /// has a library is returned untouched.
    public static func wrapping(_ data: Data, in container: FCPXMLContainer) throws -> Data {
        guard container.isUsable else { return data }

        let xml: XMLDocument
        do {
            xml = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            throw FCPXMLError.notXML
        }
        guard let root = xml.rootElement(), root.name == "fcpxml" else { throw FCPXMLError.notFCPXML }

        // Already inside a library or an event: leave it alone rather than nesting one more.
        let existing = root.children?.compactMap { ($0 as? XMLElement)?.name } ?? []
        guard !existing.contains("library"), !existing.contains("event") else { return data }

        let projects = root.children?
            .compactMap { $0 as? XMLElement }
            .filter { $0.name == "project" } ?? []
        guard !projects.isEmpty else { return data }

        let event = XMLElement(name: "event")
        var eventAttributes: [(String, String)] = [("name", container.eventName ?? "")]
        if let uid = container.eventUID { eventAttributes.append(("uid", uid)) }
        event.setOrderedAttributes(eventAttributes)

        for project in projects {
            project.detach()
            event.addChild(project)
        }

        let library = XMLElement(name: "library")
        if let url = container.libraryURL {
            library.setOrderedAttributes([("location", url.absoluteString)])
        }
        library.addChild(event)
        root.addChild(library)

        xml.isStandalone = false
        return xml.xmlData(options: [.nodePrettyPrint])
    }
}

extension XMLElement {
    /// Attributes in a stated order — `setAttributesWith` takes a dictionary and emits whatever
    /// hashing produced.
    func setOrderedAttributes(_ attributes: [(String, String)]) {
        for (name, value) in attributes {
            addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
        }
    }
}
