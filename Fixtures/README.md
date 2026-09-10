# Fixtures

Real Final Cut Pro output. The FCPXML schema is learned from these files, never from memory —
see [CLAUDE.md](../CLAUDE.md) and spec §9.

## `caption_one_clip.fcpxml`

Exported from Final Cut Pro 12.3 (macOS 26.6): a project with one 4K/59.94 asset-clip carrying one
Korean caption. The caption text is arbitrary — only the structure matters here.

Produced by: place a clip on the timeline → add a caption (⌥C) → type Korean text → select the
project in the browser → **File ▸ Export XML…**. FCP writes a `.fcpxmld` bundle; the file inside it
is `Info.fcpxml`, which is what this is.

Two things were replaced before committing, because this repo is public and they identify a
machine rather than the schema. Everything else is byte-for-byte what FCP wrote:

- the `<bookmark>` blob (a security-scoped bookmark holding volume UUIDs) → `REDACTED-…`
- absolute media/library paths under `/Users/james/…` → `/Users/example/…`

### What it settled

| Question | Answer from this file |
|---|---|
| Caption role string | `iTT?captionFormat=ITT.ko` — **not** the `iTT?captions.ko` the spec guessed |
| Where a caption lives | a `<caption>` child of the `<asset-clip>`, with `lane="1"` |
| FCPXML version | `1.14`, with `<!DOCTYPE fcpxml>` |
| Time format | rational, `<int>s` or `<int>/<int>s`, **not reduced** (`180180/60000s`) |
| Frame alignment | every caption time is an exact multiple of the *sequence* format's `frameDuration` (`1001/60000s` here), even though the asset's own format is `10/600s` |
| Caption `start` | ≈1 hour (`215999784/60000s` = exactly 215784 frames) — FCP's internal base for synthesized elements, not a timeline position |
| Text | `<text placement="bottom">` wrapping `<text-style ref="…">`, with a sibling `<text-style-def>`; a line break is its own `text-style` run |

## `caption_korean.itt`

Exported from the same Final Cut Pro project with **File ▸ Export Captions…**, ticking the
**iTT / Korean** role — the role our FCPXML import created, which is itself the confirmation that
`iTT?captionFormat=ITT.ko` was right. Nothing was edited; it is exactly what FCP wrote.

### What it settled

| Question | Answer from this file |
|---|---|
| How a caption file carries its language | `xml:lang="ko"` on the root `<tt>`. An `.srt` has nowhere to put this, which is why captions imported from SRT arrive as **English** |
| Time format | **SMPTE timecode**, `HH:MM:SS:FF` — frames, not seconds (`end="00:00:03:00"`), with `ttp:timeBase="smpte"` |
| Frame rate | `ttp:frameRate="60"` with `ttp:frameRateMultiplier="1000 1001"` — the nominal rate and the 1000/1001 pulldown, i.e. 59.94 |
| Drop frame | `ttp:dropMode="nonDrop"`, matching the sequence's `tcFormat="NDF"` |
| Line breaks | `<br/>`. FCP writes one after the last line too |
| Styling | a single `<style xml:id="normal">` and one `<region xml:id="bottom">` at `origin="0% 85%"`, `extent="100% 15%"` |

## `title_subtitle.fcpxml`

Exported from Final Cut Pro 12.3: the same project with one of FCP's built-in **Titles ▸ Subtitles
▸ Subtitle** titles on the timeline. Same redactions as above.

Captured because Final Cut Pro's caption inspector offers no font control while its Subtitle title
offers every one, so the app has to be able to write titles as well as captions.

### What it settled

| Question | Answer from this file |
|---|---|
| The template's effect `uid` | `.../Titles.localized/Subtitles.localized/Subtitle.localized/Subtitle.moti` — **the leading `...` is literal**, not an elision. Guessing a path here would have failed exactly the way `iTT?captions.ko` would have |
| Where a title lives | a `<title>` child of the `<asset-clip>` with `lane="1"`, the same anchored-item position as a caption |
| Its shape | `<text><text-style ref="…"></text>` plus a sibling `<text-style-def>` — identical to a caption's |
| Type scale | **`fontSize="100"`**, against a caption's `13`. The two are not on the same scale, so a size cannot simply be carried across |
| Internal `start` | `216216000/60000s` — exactly 216000 frames, i.e. one hour of timecode. A caption's was 215784 frames. Different conventions for the same idea |
| Defaults FCP wrote | `font="Helvetica Neue" fontSize="100" fontColor="1 1 1 1" bold="1" alignment="center" lineSpacing="22"` |

## `retimed_and_connected.fcpxml`

Cut from a real 121-clip project the user edited (2026-09-09), scrubbed of bookmarks and of every
real path, and validated against Apple's `FCPXMLv1_14.dtd`. It holds one of each thing that had
gone wrong silently:

- a **retimed** `asset-clip` with a two-point `<timeMap>` — its `start` is in the retimed output's
  time base, so reading it as media time asks for a second that is not in the file
- a **muted** clip (`adjust-volume amount="-96dB"`)
- a clip with a **connected clip beneath it**, which the reader used to never see at all
- an ordinary clip, so the tests can prove the others are excluded and this one is not

In the source project those cases were 9 retimed, 13 muted, and 49 connected clips of which 47 were
audible — 45 tagged `dialogue`. None of it was reported to anyone.
