import Foundation

/// Reads the FCPXML Final Cut Pro hands over — an exported project, or a clip dropped on the
/// extension panel — into the few facts the app needs.
///
/// Deliberately tolerant about what it does *not* need: unknown elements, metadata, effects and
/// markers are ignored rather than rejected, because FCPXML gains elements every release. It is
/// strict about what it does need, and says which attribute was missing when it fails.
public struct FCPXMLReader: Sendable {
    public init() {}

    public func read(data: Data) throws -> FCPXMLDocument {
        let xml: XMLDocument
        do {
            xml = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            throw FCPXMLError.notXML
        }
        guard let root = xml.rootElement(), root.name == "fcpxml" else { throw FCPXMLError.notFCPXML }

        let version = root.attribute(forName: "version")?.stringValue ?? "1.14"
        let formats = try formatTable(in: root)
        let assets = try assetTable(in: root)
        let sequence = try sequenceInfo(in: root, formats: formats)
        let clips = try spineClips(in: root, formats: formats, assets: assets)

        return FCPXMLDocument(version: version, sequence: sequence, clips: clips)
    }

    public func read(contentsOf url: URL) throws -> FCPXMLDocument {
        // Since 1.10 an export can be a `.fcpxmld` bundle — a directory whose payload is Info.fcpxml.
        var target = url
        if url.pathExtension.lowercased() == "fcpxmld" {
            target = url.appending(path: "Info.fcpxml")
        }
        return try read(data: try Data(contentsOf: target))
    }

    // MARK: - Resources

    private struct AssetInfo {
        var mediaURL: URL?
        var formatID: String?
        var hasAudio: Bool
        var name: String?
        var start: FCPTime
    }

    private func formatTable(in root: XMLElement) throws -> [String: FCPTime] {
        var table: [String: FCPTime] = [:]
        for element in try root.nodes(forXPath: "resources/format").compactMap({ $0 as? XMLElement }) {
            guard let id = element.attribute(forName: "id")?.stringValue else { continue }
            // An image format legitimately has no frameDuration; skip it rather than fail.
            guard let raw = element.attribute(forName: "frameDuration")?.stringValue else { continue }
            table[id] = try FCPTime.parse(raw)
        }
        return table
    }

    private func assetTable(in root: XMLElement) throws -> [String: AssetInfo] {
        var table: [String: AssetInfo] = [:]
        for element in try root.nodes(forXPath: "resources/asset").compactMap({ $0 as? XMLElement }) {
            guard let id = element.attribute(forName: "id")?.stringValue else { continue }
            let mediaRep = try element.nodes(forXPath: "media-rep").compactMap { $0 as? XMLElement }
            let source = mediaRep.first { $0.attribute(forName: "kind")?.stringValue == "original-media" }
                ?? mediaRep.first
            let src = source?.attribute(forName: "src")?.stringValue
            table[id] = AssetInfo(
                mediaURL: src.flatMap { URL(string: $0) },
                formatID: element.attribute(forName: "format")?.stringValue,
                hasAudio: element.attribute(forName: "hasAudio")?.stringValue == "1",
                name: element.attribute(forName: "name")?.stringValue,
                start: try element.attribute(forName: "start")?.stringValue.map(FCPTime.parse) ?? .zero
            )
        }
        return table
    }

    // MARK: - Sequence

    private func sequenceInfo(in root: XMLElement, formats: [String: FCPTime]) throws -> SequenceInfo? {
        guard let sequence = try root.nodes(forXPath: ".//sequence").compactMap({ $0 as? XMLElement }).first else {
            return nil   // a dropped clip can arrive with no project around it
        }
        guard let formatID = sequence.attribute(forName: "format")?.stringValue else {
            throw FCPXMLError.missingAttribute(element: "sequence", attribute: "format")
        }
        guard let frameDuration = formats[formatID] else {
            throw FCPXMLError.unknownResource(formatID)
        }

        let project = sequence.parentElement(named: "project")
        let event = project?.parentElement(named: "event")

        return SequenceInfo(
            projectName: project?.attribute(forName: "name")?.stringValue,
            eventName: event?.attribute(forName: "name")?.stringValue,
            formatID: formatID,
            frameDuration: frameDuration,
            duration: try sequence.attribute(forName: "duration")?.stringValue.map(FCPTime.parse) ?? .zero,
            tcStart: try sequence.attribute(forName: "tcStart")?.stringValue.map(FCPTime.parse) ?? .zero
        )
    }

    // MARK: - Clips

    private static let clipElements = ["asset-clip", "clip", "sync-clip", "mc-clip", "ref-clip"]

    private func spineClips(
        in root: XMLElement,
        formats: [String: FCPTime],
        assets: [String: AssetInfo]
    ) throws -> [ClipRef] {
        // A dropped clip may come with no <spine> at all, so fall back to the whole document.
        let scopes = try root.nodes(forXPath: ".//spine").compactMap { $0 as? XMLElement }
        let containers: [XMLElement] = scopes.isEmpty ? [root] : scopes

        var clips: [ClipRef] = []
        for container in containers {
            for child in container.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                guard Self.clipElements.contains(child.name ?? "") else { continue }
                clips.append(try clip(from: child, formats: formats, assets: assets))
            }
        }
        return clips
    }

    private func clip(
        from element: XMLElement,
        formats: [String: FCPTime],
        assets: [String: AssetInfo]
    ) throws -> ClipRef {
        let name = element.name ?? "clip"
        let assetID = element.attribute(forName: "ref")?.stringValue ?? ""
        let asset = assets[assetID]

        guard let durationRaw = element.attribute(forName: "duration")?.stringValue else {
            throw FCPXMLError.missingAttribute(element: name, attribute: "duration")
        }

        // `start` defaults to the asset's own start, not to zero: caption offsets are measured in
        // this clip's media time, so getting the default wrong shifts every caption.
        let start = try element.attribute(forName: "start")?.stringValue.map(FCPTime.parse)
            ?? asset?.start
            ?? .zero

        return ClipRef(
            element: name,
            assetID: assetID,
            name: element.attribute(forName: "name")?.stringValue ?? asset?.name ?? "clip",
            offset: try element.attribute(forName: "offset")?.stringValue.map(FCPTime.parse) ?? .zero,
            start: start,
            duration: try FCPTime.parse(durationRaw),
            lane: element.attribute(forName: "lane")?.stringValue.flatMap(Int.init),
            mediaURL: asset?.mediaURL,
            assetFrameDuration: asset?.formatID.flatMap { formats[$0] },
            hasAudio: asset?.hasAudio ?? true,
            captions: try captions(in: element)
        )
    }

    private func captions(in clip: XMLElement) throws -> [CaptionRef] {
        try clip.nodes(forXPath: "caption").compactMap { $0 as? XMLElement }.map { element in
            // FCP splits a caption's text across runs — one per style, with a line break landing in
            // a run of its own — so the text is the concatenation, not the first run.
            let runs = try element.nodes(forXPath: "text/text-style").compactMap { ($0 as? XMLElement)?.stringValue }
            let text = runs.joined()

            guard let durationRaw = element.attribute(forName: "duration")?.stringValue else {
                throw FCPXMLError.missingAttribute(element: "caption", attribute: "duration")
            }
            return CaptionRef(
                role: element.attribute(forName: "role")?.stringValue ?? "",
                lane: element.attribute(forName: "lane")?.stringValue.flatMap(Int.init),
                offset: try element.attribute(forName: "offset")?.stringValue.map(FCPTime.parse) ?? .zero,
                start: try element.attribute(forName: "start")?.stringValue.map(FCPTime.parse) ?? .zero,
                duration: try FCPTime.parse(durationRaw),
                name: element.attribute(forName: "name")?.stringValue,
                // Only the trailing line break FCP appends is dropped; interior breaks are the
                // caption's own two lines, and leading/trailing spaces are the editor's.
                text: text.trimmingCharacters(in: .newlines)
            )
        }
    }
}

private extension XMLElement {
    func parentElement(named name: String) -> XMLElement? {
        var node: XMLNode? = parent
        while let current = node {
            if let element = current as? XMLElement, element.name == name { return element }
            node = current.parent
        }
        return nil
    }
}
