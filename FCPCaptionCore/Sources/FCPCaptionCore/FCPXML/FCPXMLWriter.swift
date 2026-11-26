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
    public var style: CaptionStyle
    /// What to write onto the timeline.
    public var form: Form

    /// Captions and titles are different things, and Final Cut Pro treats them differently.
    ///
    /// A **caption** goes on the caption lane: it is a subtitle track, it can be exported as a
    /// file, toggled by role, and FCP's inspector will not let anyone change its font. A **title**
    /// is text in the picture: every type control is editable in FCP, and it is not a subtitle
    /// track at all — no caption index, no export, and it burns into the render.
    ///
    /// They coexist on one timeline, so `both` is a real answer.
    public enum Form: String, Sendable, Equatable, Codable, CaseIterable {
        case caption, title, both

        public var writesCaptions: Bool { self != .title }
        public var writesTitles: Bool { self != .caption }

        public var korean: String {
            switch self {
            case .caption: "캡션"
            case .title: "타이틀"
            case .both: "둘 다"
            }
        }

        public var summary: String {
            switch self {
            case .caption: "자막 트랙으로 들어갑니다. 자막 파일로 내보낼 수 있지만 Final Cut Pro에서 글꼴을 바꿀 수 없습니다."
            case .title: "화면에 얹는 글자입니다. Final Cut Pro에서 글꼴을 자유롭게 바꿀 수 있지만 자막 트랙은 아닙니다."
            case .both: "둘 다 만듭니다. 캡션은 역할로 껐다 켤 수 있어 한 타임라인에 함께 둘 수 있습니다."
            }
        }
    }

    public init(
        language: String = "ko",
        lane: Int? = nil,
        style: CaptionStyle = .default,
        form: Form = .caption
    ) {
        self.language = language
        self.lane = lane
        self.style = style
        self.form = form
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
        let anchor = try self.anchor(for: clip, located: try element(for: clip, in: root), root: root)
        let target = anchor.element
        let lane = try self.lane ?? freeLane(in: target)

        var nextStyleID = try nextStyleIdentifier(in: root)
        let occupied = occupiedRanges(in: target, language: language, frameDuration: frameDuration)
        let all = placements(for: captions, in: anchor, frameDuration: frameDuration)
        let free = all.compactMap { avoiding(occupied, $0, frameDuration: frameDuration) }
        // Captions inside the clip that its parent's span cut off. Not the ones past the clip's
        // own end — those never had a place on the timeline.
        var unbounded = anchor
        unbounded.bounds = anchor.origin..<(anchor.origin + clip.duration)
        let cutOff = anchor.bounds == unbounded.bounds
            ? 0
            : placements(for: captions, in: unbounded, frameDuration: frameDuration).count - all.count

        let titleLane = form == .both ? lane + 1 : lane
        var effectID: String?
        if form.writesTitles { effectID = try titleEffectID(in: root) }

        // A title's attributes are checked against **different grids**, which the reference
        // export states plainly for a clip conforming 60p into a 59.94 timeline:
        //
        //     offset="31/20s"            93 frames at 60      · 92.907 at 59.94
        //     duration="300300/60000s"   300.3 frames at 60   · 300 at 59.94
        //
        // So the position is in the clip's own time base and the length is in the sequence's.
        // Aligning both to one grid earns "The item is not on an edit frame boundary" from the
        // importer — first for every offset, then for every duration.
        let titleGrid = anchor.titleGrid ?? frameDuration
        let titlePlacements = titleGrid == frameDuration
            ? free
            : placements(for: captions, in: anchor, frameDuration: titleGrid)
                .compactMap { avoiding(occupied, $0, frameDuration: titleGrid) }

        for placement in free where form.writesCaptions {
            let duration = placement.end - placement.start
            do {
                let styleID = "ts\(nextStyleID)"
                nextStyleID += 1
                insert(captionElement(placement.caption,
                                      start: placement.start,
                                      duration: duration,
                                      frameDuration: frameDuration,
                                      styleID: styleID,
                                      lane: lane),
                       into: target)
            }
        }

        if form.writesTitles, let effectID {
            for placement in titlePlacements {
                let styleID = "ts\(nextStyleID)"
                nextStyleID += 1
                // Length on the sequence grid, position on the clip's — see above.
                var duration = (placement.end - placement.start)
                    .aligned(to: frameDuration, rounding: .nearest)
                if duration.numerator <= 0 { duration = frameDuration }
                insert(titleElement(placement.caption,
                                    offset: placement.start,
                                    duration: duration,
                                    sequenceFrameDuration: frameDuration,
                                    styleID: styleID,
                                    lane: titleLane,
                                    effectID: effectID),
                       into: target)
            }
        }

        // Final Cut Pro's own exports carry no standalone declaration, and pretty-printed
        // whitespace inside element-only content is a validity error under `standalone="yes"` —
        // which Foundation writes by default. Apple's DTD rejects the document over it.
        xml.isStandalone = false
        return WriteResult(
            document: xml.xmlData(options: [.nodePrettyPrint]),
            written: free.count,
            skipped: all.count - free.count + cutOff
        )
    }

    // MARK: - Placement

    private struct Placement {
        var caption: Caption
        var start: FCPTime
        var end: FCPTime
    }

    /// Where captions for a clip are attached, and in which time base.
    private struct Anchor {
        /// The element the captions become children of.
        var element: XMLElement
        /// The time, in `element`'s base, at which caption second 0 falls — where the clip starts.
        var origin: FCPTime
        /// Captions are kept inside this span of `element`'s time.
        var bounds: Range<FCPTime>
        /// The grid a title's `offset` must sit on: `element`'s own format. Nil means the sequence's.
        var titleGrid: FCPTime?
    }

    /// Decides which element carries a clip's captions.
    ///
    /// Normally the clip itself. A **connected** clip cannot carry them: Final Cut Pro only keeps
    /// anchored items on clips in a storyline, and silently drops any anchored to a connected
    /// clip on import. Seen in a real project (2026-11-25): titles written to 21 connected clips —
    /// detached audio and a synced mic among them — all vanished, while the 106 on spine clips
    /// survived. Across every real export in hand, over 900 anchored items, not one sits inside
    /// another anchored item.
    ///
    /// So a connected clip's captions are attached to the clip it hangs from, in that clip's time:
    /// a connected clip's `offset` is exactly where its `start` falls in its parent. They are kept
    /// inside the parent's own span — an anchor point outside its parent is not something a real
    /// export has shown, so a caption that would need one is dropped and counted as skipped.
    private func anchor(for clip: ClipRef, located element: XMLElement, root: XMLElement) throws -> Anchor {
        let own = Anchor(
            element: element,
            origin: clip.start,
            bounds: clip.start..<(clip.start + clip.duration),
            titleGrid: clip.assetFrameDuration
        )
        guard element.attribute(forName: "lane") != nil,
              let parent = element.parent as? XMLElement,
              parent.name != "spine"
        else { return own }

        let parentName = parent.name ?? "clip"
        guard let durationRaw = parent.attribute(forName: "duration")?.stringValue else {
            throw FCPXMLError.missingAttribute(element: parentName, attribute: "duration")
        }
        let parentStart = try startOf(parent, root: root)
        let parentEnd = parentStart + (try FCPTime.parse(durationRaw))
        let lower = max(clip.offset, parentStart)
        let upper = max(lower, min(clip.offset + clip.duration, parentEnd))
        return Anchor(
            element: parent,
            origin: clip.offset,
            bounds: lower..<upper,
            titleGrid: try formatFrameDuration(of: parent, root: root)
        )
    }

    /// An element's `start`, defaulting as the reader does for an `asset-clip` — to its asset's
    /// own start. Any other element with no `start` is an error rather than a guess.
    private func startOf(_ element: XMLElement, root: XMLElement) throws -> FCPTime {
        if let raw = element.attribute(forName: "start")?.stringValue { return try FCPTime.parse(raw) }
        if element.name == "asset-clip", let resource = try resource(element.attribute(forName: "ref")?.stringValue, in: root) {
            return try resource.attribute(forName: "start")?.stringValue.map(FCPTime.parse) ?? .zero
        }
        throw FCPXMLError.missingAttribute(element: element.name ?? "clip", attribute: "start")
    }

    /// The frame duration of an element's own format: its `format`, else that of the asset or
    /// multicam it references. Nil when it has none (a gap), which means the sequence's.
    private func formatFrameDuration(of element: XMLElement, root: XMLElement) throws -> FCPTime? {
        var formatID = element.attribute(forName: "format")?.stringValue
        if formatID == nil, let resource = try resource(element.attribute(forName: "ref")?.stringValue, in: root) {
            formatID = resource.attribute(forName: "format")?.stringValue
                ?? resource.elements(forName: "multicam").first?.attribute(forName: "format")?.stringValue
        }
        guard let formatID else { return nil }
        guard let format = try resource(formatID, in: root),
              let raw = format.attribute(forName: "frameDuration")?.stringValue
        else { throw FCPXMLError.unknownResource(formatID) }
        return try FCPTime.parse(raw)
    }

    private func resource(_ id: String?, in root: XMLElement) throws -> XMLElement? {
        guard let id else { return nil }
        return try root.nodes(forXPath: "resources/*").compactMap { $0 as? XMLElement }
            .first { $0.attribute(forName: "id")?.stringValue == id }
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
        in anchor: Anchor,
        frameDuration: FCPTime
    ) -> [Placement] {
        let oneFrame = frameDuration
        let clipStart = anchor.bounds.lowerBound
        let clipEnd = anchor.bounds.upperBound

        var placements: [Placement] = []
        for caption in captions.sorted(by: { $0.start < $1.start }) {
            var start = (anchor.origin + FCPTime(seconds: caption.start))
                .aligned(to: frameDuration, rounding: .down)
            var end = (anchor.origin + FCPTime(seconds: caption.end))
                .aligned(to: frameDuration, rounding: .up)

            if end <= clipStart || start >= clipEnd { continue }
            if start < clipStart { start = clipStart }
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
        let styleElement = XMLElement(name: "text-style")
        styleElement.setOrderedAttributes(style.fcpxmlAttributes)
        definition.addChild(styleElement)
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

    /// Final Cut Pro's built-in Subtitle title, taken from a real export.
    ///
    /// The leading `...` is **literal** — it is how FCP refers to its own template root, not an
    /// elision in the fixture. A path built from where the template sits on disk does not work.
    static let subtitleEffectUID =
        ".../Titles.localized/Subtitles.localized/Subtitle.localized/Subtitle.moti"
    static let subtitleEffectName = "Subtitle"

    /// The Subtitle template draws its own rounded box behind the text — 85% opaque by default —
    /// and ignores the `backgroundColor` in `text-style`. Its opacity is a published parameter,
    /// written exactly as Final Cut Pro wrote it when the box was cleared by hand in the inspector
    /// (`Fixtures/title_no_background.fcpxml`). The key is Motion's internal path; it cannot be
    /// derived, only copied.
    static let subtitleBackgroundOpacity = (
        name: "Background Opacity",
        key: "9999/3336674837/3336685305/3336678548/1/200/202"
    )

    /// The id of the Subtitle effect resource, adding it to `resources` if the document has none.
    private func titleEffectID(in root: XMLElement) throws -> String {
        let effects = try root.nodes(forXPath: "resources/effect").compactMap { $0 as? XMLElement }
        if let existing = effects.first(where: {
            $0.attribute(forName: "uid")?.stringValue == Self.subtitleEffectUID
        }), let id = existing.attribute(forName: "id")?.stringValue {
            return id
        }

        guard let resources = try root.nodes(forXPath: "resources").compactMap({ $0 as? XMLElement }).first
        else { throw FCPXMLError.missingAttribute(element: "fcpxml", attribute: "resources") }

        // Resource ids are document-wide; continue past whatever is already there.
        let used = try root.nodes(forXPath: "resources/*")
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue }
            .compactMap { Int($0.dropFirst()) }
        let id = "r\((used.max() ?? 0) + 1)"

        let effect = XMLElement(name: "effect")
        effect.setOrderedAttributes([
            ("id", id),
            ("name", Self.subtitleEffectName),
            ("uid", Self.subtitleEffectUID),
        ])
        resources.addChild(effect)
        return id
    }

    private func titleElement(
        _ caption: Caption,
        offset: FCPTime,
        duration: FCPTime,
        sequenceFrameDuration: FCPTime,
        styleID: String,
        lane: Int,
        effectID: String
    ) -> XMLElement {
        let element = XMLElement(name: "title")
        element.setOrderedAttributes([
            ("ref", effectID),
            ("lane", String(lane)),
            ("offset", offset.description),
            ("name", caption.lines.first ?? caption.text),
            // One hour of timecode on the sequence grid: the reference export writes
            // 216216000/60000s, which is exactly 216000 frames at 59.94.
            ("start", FCPTime(216_000 * sequenceFrameDuration.numerator, sequenceFrameDuration.denominator).description),
            ("duration", duration.description),
        ])

        // Parameters come before the text, as in the export. Left out when there is a background,
        // so the template keeps its own default rather than one copied from it.
        if !style.drawsBackground {
            let param = XMLElement(name: "param")
            param.setOrderedAttributes([
                ("name", Self.subtitleBackgroundOpacity.name),
                ("key", Self.subtitleBackgroundOpacity.key),
                ("value", "0"),
            ])
            element.addChild(param)
        }

        let text = XMLElement(name: "text")
        let run = XMLElement(name: "text-style", stringValue: caption.text)
        run.setOrderedAttributes([("ref", styleID)])
        text.addChild(run)
        element.addChild(text)

        let definition = XMLElement(name: "text-style-def")
        definition.setOrderedAttributes([("id", styleID)])
        let styleElement = XMLElement(name: "text-style")
        styleElement.setOrderedAttributes(style.titleAttributes)
        definition.addChild(styleElement)
        element.addChild(definition)

        return element
    }

    // MARK: - Locating

    /// Finds the element a `ClipRef` was read from.
    ///
    /// `ref` and `offset` used to be the whole identity, which breaks on a `<clip>` wrapper — a
    /// detached-audio clip has no `ref` at all, and its `offset` is in its parent's time, so two
    /// of them under different parents can share one. Lane, `start` and `duration` narrow it
    /// down; if it is still ambiguous that is an error, never a coin toss, because the loser
    /// would get someone else's captions.
    private func element(for clip: ClipRef, in root: XMLElement) throws -> XMLElement {
        func time(_ element: XMLElement, _ attribute: String) -> FCPTime? {
            (try? element.attribute(forName: attribute)?.stringValue.map(FCPTime.parse)) ?? nil
        }
        let candidates = try root.nodes(forXPath: ".//\(clip.element)").compactMap { $0 as? XMLElement }
            .filter { candidate in
                (candidate.attribute(forName: "ref")?.stringValue ?? "") == clip.assetID
                    && (time(candidate, "offset") ?? .zero) == clip.offset
            }
        guard candidates.count > 1 else {
            guard let match = candidates.first else { throw FCPXMLError.clipNotFound(clip.name) }
            return match
        }
        let narrowed = candidates.filter { candidate in
            candidate.attribute(forName: "lane")?.stringValue.flatMap(Int.init) == clip.lane
                && time(candidate, "duration") == clip.duration
                && (time(candidate, "start").map { $0 == clip.start } ?? true)
        }
        guard narrowed.count == 1, let match = narrowed.first else { throw FCPXMLError.clipNotFound(clip.name) }
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

