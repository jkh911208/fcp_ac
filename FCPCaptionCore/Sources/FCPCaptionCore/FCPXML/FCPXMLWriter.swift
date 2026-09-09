import Foundation

/// Writes captions back into the FCPXML document Final Cut Pro gave us.
///
/// It edits that document rather than composing a new one: the version, resources, media bookmarks
/// and every element we don't understand survive untouched, which is also why nothing here
/// hardcodes a schema version. What it adds is exactly what a real FCP export contains for a
/// caption — see `Fixtures/README.md`.
public struct FCPXMLWriter: Sendable {
    /// Language subtag used in the caption role, e.g. `ko` → `iTT?captionFormat=ITT.ko`.
    public var language: String
    /// Captions go on their own lane above the clip; FCP's own export uses lane 1.
    public var lane: Int
    /// The font FCP chose for a Korean caption in the reference export.
    public var font: String
    public var fontSize: Int

    public init(language: String = "ko", lane: Int = 1, font: String = ".Apple SD Gothic NeoI", fontSize: Int = 13) {
        self.language = language
        self.lane = lane
        self.font = font
        self.fontSize = fontSize
    }

    public var role: String { "iTT?captionFormat=ITT.\(language)" }

    /// Final Cut Pro writes a synthesized element's internal `start` as one hour, frame-aligned —
    /// `215999784/60000s` in the reference export. It is a time base, not a timeline position.
    static let syntheticStartSeconds: TimeInterval = 3600

    /// Returns the document with `captions` attached to `clip`.
    ///
    /// Existing captions are left alone — appending is never destructive, so a second run adds a
    /// second set rather than quietly deleting captions the editor typed by hand.
    public func addingCaptions(_ captions: [Caption], to clip: ClipRef, inDocument data: Data) throws -> Data {
        let xml: XMLDocument
        do {
            xml = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            throw FCPXMLError.notXML
        }
        guard let root = xml.rootElement(), root.name == "fcpxml" else { throw FCPXMLError.notFCPXML }

        let frameDuration = try frameDuration(in: root, clip: clip)
        let target = try element(for: clip, in: root)

        var nextStyleID = try nextStyleIdentifier(in: root)
        let clipEnd = clip.start + clip.duration

        for caption in captions {
            // Start rounds down and end rounds up (see FCPTime.FrameRounding): quantization may
            // show a caption a frame early or hold it a frame long, never cut a word off.
            var start = (clip.start + FCPTime(seconds: caption.start))
                .aligned(to: frameDuration, rounding: .down)
            var end = (clip.start + FCPTime(seconds: caption.end))
                .aligned(to: frameDuration, rounding: .up)

            // A caption that falls entirely outside the clip is dropped; one that straddles an edge
            // is trimmed to it. FCP rejects a caption that runs past its parent.
            if end <= clip.start || start >= clipEnd { continue }
            if start < clip.start { start = clip.start }
            if end > clipEnd { end = clipEnd }

            let oneFrame = FCPTime(frameDuration.numerator, frameDuration.denominator)
            var duration = end - start
            if duration < oneFrame { duration = oneFrame }
            if start + duration > clipEnd { continue }

            let styleID = "ts\(nextStyleID)"
            nextStyleID += 1
            target.addChild(captionElement(caption, start: start, duration: duration,
                                           frameDuration: frameDuration, styleID: styleID))
        }

        // Final Cut Pro's own exports carry no standalone declaration, and pretty-printed
        // whitespace inside element-only content is a validity error under `standalone="yes"` —
        // which Foundation writes by default. Apple's DTD rejects the document over it.
        xml.isStandalone = false
        return xml.xmlData(options: [.nodePrettyPrint])
    }

    // MARK: - Building

    private func captionElement(
        _ caption: Caption,
        start: FCPTime,
        duration: FCPTime,
        frameDuration: FCPTime,
        styleID: String
    ) -> XMLElement {
        let element = XMLElement(name: "caption")
        // Attribute order follows the reference export, so a diff against a real FCP file shows
        // only what actually differs.
        element.setOrderedAttributes([
            ("lane", String(lane)),
            ("offset", start.description),
            ("name", caption.lines.first ?? caption.text),
            ("start", FCPTime.seconds(Self.syntheticStartSeconds, alignedTo: frameDuration, rounding: .nearest).description),
            ("duration", duration.description),
            ("role", role),
        ])

        let text = XMLElement(name: "text")
        text.setOrderedAttributes([("placement", "bottom")])
        let run = XMLElement(name: "text-style", stringValue: caption.text)
        run.setOrderedAttributes([("ref", styleID)])
        text.addChild(run)
        element.addChild(text)

        let definition = XMLElement(name: "text-style-def")
        definition.setOrderedAttributes([("id", styleID)])
        let style = XMLElement(name: "text-style")
        style.setOrderedAttributes([
            ("font", font),
            ("fontSize", String(fontSize)),
            ("fontFace", "Regular"),
            ("fontColor", "1 1 1 1"),
            ("backgroundColor", "0 0 0 1"),
        ])
        definition.addChild(style)
        element.addChild(definition)

        return element
    }

    // MARK: - Locating

    private func element(for clip: ClipRef, in root: XMLElement) throws -> XMLElement {
        let candidates = try root.nodes(forXPath: ".//\(clip.element)").compactMap { $0 as? XMLElement }
        let match = candidates.first { candidate in
            guard candidate.attribute(forName: "ref")?.stringValue == clip.assetID else { return false }
            let offset = (try? candidate.attribute(forName: "offset")?.stringValue.map(FCPTime.parse)) ?? nil
            return (offset ?? .zero) == clip.offset
        }
        guard let match else { throw FCPXMLError.clipNotFound(clip.name) }
        return match
    }

    /// The frame grid to quantize onto: the sequence's format, falling back to the clip's own asset
    /// format only when the document has no sequence (a bare dropped clip). If neither is present
    /// this throws — guessing a frame rate would silently misplace every caption.
    private func frameDuration(in root: XMLElement, clip: ClipRef) throws -> FCPTime {
        if let sequence = try root.nodes(forXPath: ".//sequence").compactMap({ $0 as? XMLElement }).first,
           let formatID = sequence.attribute(forName: "format")?.stringValue {
            guard let format = try root.nodes(forXPath: "resources/format")
                .compactMap({ $0 as? XMLElement })
                .first(where: { $0.attribute(forName: "id")?.stringValue == formatID }),
                let raw = format.attribute(forName: "frameDuration")?.stringValue
            else { throw FCPXMLError.unknownResource(formatID) }
            return try FCPTime.parse(raw)
        }
        guard let assetFrameDuration = clip.assetFrameDuration else {
            throw FCPXMLError.missingAttribute(element: "format", attribute: "frameDuration")
        }
        return assetFrameDuration
    }

    /// `text-style-def` ids are document-scoped, so new ones continue past whatever FCP already
    /// wrote (`ts1`, `ts2`, …) instead of colliding with it.
    private func nextStyleIdentifier(in root: XMLElement) throws -> Int {
        let existing = try root.nodes(forXPath: ".//text-style-def")
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue }
            .compactMap { Int($0.dropFirst(2)) }
        return (existing.max() ?? 0) + 1
    }
}


private extension XMLElement {
    /// `setAttributesWith` takes a dictionary, so it emits attributes in whatever order hashing
    /// produced. FCPXML does not care, but people reading diffs do.
    func setOrderedAttributes(_ attributes: [(String, String)]) {
        for (name, value) in attributes {
            addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
        }
    }
}
