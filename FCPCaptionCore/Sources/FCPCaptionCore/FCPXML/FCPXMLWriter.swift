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
    /// The lane to write on, or `nil` to pick one that is free.
    ///
    /// Captions on one lane may not overlap, and a clip can already carry the editor's own —
    /// appending ours to lane 1 on top of theirs produces a document Final Cut Pro can reject.
    /// Automatic means: lane 1 when the clip has no captions, otherwise one above the highest
    /// lane already in use, which is also how a second language would sit alongside a first.
    public var lane: Int?
    /// The font FCP chose for a Korean caption in the reference export.
    public var font: String
    public var fontSize: Int

    public init(language: String = "ko", lane: Int? = nil, font: String = ".Apple SD Gothic NeoI", fontSize: Int = 13) {
        self.language = language
        self.lane = lane
        self.font = font
        self.fontSize = fontSize
    }

    public var role: String { "iTT?captionFormat=ITT.\(language)" }

    /// Final Cut Pro writes a synthesized element's internal `start` as one hour, frame-aligned —
    /// `215999784/60000s` in the reference export. It is a time base, not a timeline position.
    static let syntheticStartSeconds: TimeInterval = 3600

    /// What a write actually did. `skipped` is not a detail: a caption that collided with the
    /// editor's own is silently missing from the timeline unless somebody says so.
    public struct WriteResult: Sendable {
        public var document: Data
        public var written: Int
        public var skipped: Int
    }

    /// Returns the document with `captions` attached to `clip`.
    ///
    /// Existing captions are left alone — appending is never destructive, so a second run adds a
    /// second set rather than quietly deleting captions the editor typed by hand.
    public func addingCaptions(_ captions: [Caption], to clip: ClipRef, inDocument data: Data) throws -> Data {
        try write(captions, to: clip, inDocument: data).document
    }

    public func write(_ captions: [Caption], to clip: ClipRef, inDocument data: Data) throws -> WriteResult {
        let xml: XMLDocument
        do {
            xml = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            throw FCPXMLError.notXML
        }
        guard let root = xml.rootElement(), root.name == "fcpxml" else { throw FCPXMLError.notFCPXML }

        let frameDuration = try frameDuration(in: root, clip: clip)
        let target = try element(for: clip, in: root)
        let lane = try self.lane ?? freeLane(in: target)

        var nextStyleID = try nextStyleIdentifier(in: root)
        let occupied = occupiedRanges(in: target, language: language, frameDuration: frameDuration)
        let all = placements(for: captions, clip: clip, frameDuration: frameDuration)
        let free = all.compactMap { avoiding(occupied, $0, frameDuration: frameDuration) }

        for placement in free {
            let styleID = "ts\(nextStyleID)"
            nextStyleID += 1
            insert(captionElement(placement.caption,
                                  start: placement.start,
                                  duration: placement.end - placement.start,
                                  frameDuration: frameDuration,
                                  styleID: styleID,
                                  lane: lane),
                   into: target)
        }

        // Final Cut Pro's own exports carry no standalone declaration, and pretty-printed
        // whitespace inside element-only content is a validity error under `standalone="yes"` —
        // which Foundation writes by default. Apple's DTD rejects the document over it.
        xml.isStandalone = false
        return WriteResult(
            document: xml.xmlData(options: [.nodePrettyPrint]),
            written: free.count,
            skipped: all.count - free.count
        )
    }

    // MARK: - Placement

    private struct Placement {
        var caption: Caption
        var start: FCPTime
        var end: FCPTime
    }

    /// Turns caption seconds into frame-aligned positions inside the clip.
    ///
    /// Three things happen here, in order, and the order matters:
    /// 1. each edge is snapped to a frame — start down, end up, so a word is never clipped;
    /// 2. captions outside the clip are dropped and ones straddling its end are trimmed;
    /// 3. **overlaps introduced by step 1 are removed.** Rounding a caption's end up and the next
    ///    caption's start down can make two adjacent captions collide by a frame even though they
    ///    did not overlap in seconds — and two captions on one lane may not overlap. The earlier
    ///    caption gives way, matching what `CaptionBuilder` already does in the time domain.
    private func placements(
        for captions: [Caption],
        clip: ClipRef,
        frameDuration: FCPTime
    ) -> [Placement] {
        let oneFrame = frameDuration
        let clipEnd = clip.start + clip.duration

        var placements: [Placement] = []
        for caption in captions.sorted(by: { $0.start < $1.start }) {
            var start = (clip.start + FCPTime(seconds: caption.start))
                .aligned(to: frameDuration, rounding: .down)
            var end = (clip.start + FCPTime(seconds: caption.end))
                .aligned(to: frameDuration, rounding: .up)

            if end <= clip.start || start >= clipEnd { continue }
            if start < clip.start { start = clip.start }
            if end > clipEnd { end = clipEnd }
            if end - start < oneFrame { end = start + oneFrame }
            if end > clipEnd { continue }

            if var previous = placements.last, previous.end > start {
                previous.end = start
                if previous.end - previous.start < oneFrame {
                    // The earlier caption cannot shrink below a frame, so this one starts later.
                    previous.end = previous.start + oneFrame
                    start = previous.end
                    if start >= end { end = start + oneFrame }
                    if end > clipEnd { continue }
                }
                placements[placements.count - 1] = previous
            }

            placements.append(Placement(caption: caption, start: start, end: end))
        }
        return placements
    }

    /// Time ranges already taken by captions **in the same language**, whatever lane they sit on.
    ///
    /// Final Cut Pro validates caption overlap per language, not per lane: put a caption over one
    /// the editor typed and both turn red in the timeline, even on separate lanes. Confirmed by
    /// importing a document that did exactly that.
    private func occupiedRanges(
        in clip: XMLElement,
        language: String,
        frameDuration: FCPTime
    ) -> [(start: FCPTime, end: FCPTime)] {
        let captions = (try? clip.nodes(forXPath: "caption").compactMap { $0 as? XMLElement }) ?? []
        return captions.compactMap { element -> (FCPTime, FCPTime)? in
            let role = element.attribute(forName: "role")?.stringValue ?? ""
            guard role.hasSuffix(".\(language)") || role == self.role else { return nil }
            guard let offsetRaw = element.attribute(forName: "offset")?.stringValue,
                  let durationRaw = element.attribute(forName: "duration")?.stringValue,
                  let offset = try? FCPTime.parse(offsetRaw),
                  let duration = try? FCPTime.parse(durationRaw)
            else { return nil }
            return (offset, offset + duration)
        }
    }

    /// Trims a placement clear of the ranges the editor's captions already own, or drops it.
    ///
    /// Trimming only works from the edges. A caption that would straddle an existing one — the
    /// editor's caption sitting in the middle of ours — is skipped rather than split, because
    /// splitting would show the same sentence twice.
    private func avoiding(
        _ occupied: [(start: FCPTime, end: FCPTime)],
        _ placement: Placement,
        frameDuration: FCPTime
    ) -> Placement? {
        var placement = placement
        for range in occupied.sorted(by: { $0.start < $1.start }) {
            if range.end <= placement.start || range.start >= placement.end { continue }
            if range.start <= placement.start && range.end >= placement.end { return nil }
            if range.start <= placement.start {
                placement.start = range.end
            } else if range.end >= placement.end {
                placement.end = range.start
            } else {
                return nil   // theirs sits inside ours
            }
            if placement.end - placement.start < frameDuration { return nil }
        }
        return placement
    }

    // MARK: - Building

    private func captionElement(
        _ caption: Caption,
        start: FCPTime,
        duration: FCPTime,
        frameDuration: FCPTime,
        styleID: String,
        lane: Int
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

    /// Elements that must come *after* an anchored item, from Apple's own DTD. A clip's content
    /// model is
    ///
    ///     (note?, %timing-params;, %intrinsic-params;, (%anchor_item;)*, (%marker_item;)*,
    ///      audio-channel-source*, (%video_filter_item;)*, filter-audio*, metadata?)
    ///
    /// and `caption` is an `%anchor_item;`. Appending to the end therefore only works on a clip
    /// that happens to have none of these — which the reference export did, and a real clip with a
    /// Dialogue-1/Dialogue-2 audio configuration did not: Final Cut Pro refused the import with
    /// "Element asset-clip content does not follow the DTD".
    private static let elementsAfterAnchoredItems: Set<String> = [
        "marker", "chapter-marker", "rating", "keyword", "analysis-marker", "hidden-clip-marker",
        "audio-channel-source", "filter-video", "filter-video-mask", "filter-audio", "metadata",
    ]

    /// Puts a caption where the DTD says an anchored item goes: after any that are already there,
    /// and before the first element belonging to a later group.
    private func insert(_ caption: XMLElement, into clip: XMLElement) {
        let children = clip.children?.compactMap { $0 as? XMLElement } ?? []
        guard let boundary = children.firstIndex(where: {
            Self.elementsAfterAnchoredItems.contains($0.name ?? "")
        }) else {
            clip.addChild(caption)
            return
        }
        clip.insertChild(caption, at: clip.children?.firstIndex(of: children[boundary]) ?? boundary)
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

    /// The lowest lane that carries no captions yet, never below 1.
    private func freeLane(in clip: XMLElement) throws -> Int {
        let used = try clip.nodes(forXPath: "caption")
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "lane")?.stringValue }
            .compactMap(Int.init)
        guard let highest = used.max() else { return 1 }
        return max(1, highest + 1)
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
