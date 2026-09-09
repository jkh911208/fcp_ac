# PROGRESS

Running state of the project. Read this first after a break — it is meant to be enough on its own.
Plan of record: [FCP_CAPTION_SPEC.md](FCP_CAPTION_SPEC.md). Working rules: [CLAUDE.md](CLAUDE.md).

**Last updated:** 2026-09-09 · **M2 is answered — see below.** Current milestone: M1 in progress. **The pipeline works end to
end from the command line** — see "Use it today" in the README. Only the extension shell is missing,
and it is blocked on an Apple SDK download.
**Repo:** <https://github.com/jkh911208/fcp_ac> · **Site:** <https://jkh911208.github.io/fcp_ac/>

> Bootstrap note: this first commit was made directly on `main` in the main working tree, because
> the repo and its remote did not exist yet. From M1 on, the rule in `CLAUDE.md` applies —
> every change is cut as a worktree off `origin/main` and lands through a PR.

## Where it stands

M0 (the transcription spike) is complete and verified end to end on this machine:
Korean audio → WhisperKit → caption units → `.srt`.

Smoke run, 18.6s of synthesized Korean speech (`say -v Yuna`, no copyright encumbrance):

| | |
|---|---|
| First run (model download included) | 600s — ~600MB of `openai_whisper-large-v3-v20240930_turbo` |
| Second run (model cached) | **5.8s**, most of it CoreML model load |
| Output | 31 words → 7 captions, transcript accurate, splits landed on sentence boundaries |

## Done

### M1 — FCPXML layer (this branch)

The schema was learned from a real Final Cut Pro 12.3 export, now committed as
`Fixtures/caption_one_clip.fcpxml` (see `Fixtures/README.md` for how it was made and what was
redacted). **The spec's guess was wrong on the one attribute that matters**: the caption role is
`iTT?captionFormat=ITT.ko`, not `iTT?captions.ko`.

- `FCPTime` — exact rational seconds, parsed and printed the way FCP writes them (unreduced,
  `180180/60000s`, `0s`). Frame alignment with a **named rounding policy**: a caption's start
  rounds down and its end rounds up, so quantization can only show a caption early and hold it
  long, never clip a word.
- `FCPXMLReader` — version, sequence (project/event/format/frameDuration/duration/tcStart), clips
  (asset id, media URL, offset/start/duration, lane, the asset's own frame duration) and any
  captions already attached. Tolerant of unknown elements, strict about what it needs, and it says
  which attribute was missing. Handles a bare dropped clip with no project around it.
- `FCPXMLWriter` — **edits the document FCP gave us** rather than composing a new one, so the
  version, resources, media bookmarks and everything we don't understand survive untouched.
  Captions are appended (never destructive), clamped to the clip, given collision-free
  `text-style-def` ids, and the language drives the role.
- **Output is validated against Apple's own DTD** — `FCPXMLv1_14.dtd`, shipped inside Final Cut
  Pro — as part of the test suite. That check is skipped (visibly) where FCP isn't installed,
  never silently passed.
- 53 tests, all green.

Two bugs this caught, both now frozen as tests: `FCPTime` arithmetic overflowed `Int` on FCP's
~1-hour caption `start` values (fixed by working over the least common denominator), and
Foundation writes `standalone="yes"`, which makes Apple's DTD reject every pretty-printed
document.

### M1 — audio extraction and the full pipeline (this branch)

- `AudioExtractor` — AVFoundation only (`AVAssetReader` → 16 kHz mono WAV), which is what makes
  video files work at all: WhisperKit loads audio through `AVAudioFile`, and that cannot open a
  `.mov`. Extracts only the range the clip actually uses, so trimmed-away footage isn't captioned.
- `CaptionPipeline` — FCPXML in, captioned FCPXML out, with staged Korean progress text. This is
  the piece the extension panel will drive; the CLI drives it today.
- `fcpcaption-cli` now takes either: a `.fcpxml`/`.fcpxmld` (→ `*.captioned.fcpxml` to re-import)
  or a media file (→ `.srt`).

**Verified on the user's own 24.5s Korean clip:** 41 words → 5 captions in 5.9s with the model
cached, and the output validates against Apple's DTD. Two bugs that only appeared when running it
for real, both now tests:
- our captions landed on lane 1 **on top of a caption the editor had already typed there**. The
  writer now picks the first free lane, so the editor's work is never overlapped.
- frame quantization (start rounds down, end rounds up) made two adjacent captions overlap by a
  frame even though they didn't overlap in seconds — invalid on one caption lane.

### M2 — how captions actually get into Final Cut Pro (answered 2026-09-09)

Both paths were tried in real Final Cut Pro 12.3, on a real project. Spec §10's ladder now has
measured rungs instead of guesses:

| Path | What happens | Cost |
|---|---|---|
| **Caption file + File ▸ Import ▸ Captions…** | **Captions land on the open, existing project. No dialog at all.** Nothing is duplicated, the timeline the editor is working in is the one that gets the captions. | The user picks the file from a dialog |
| FCPXML + File ▸ Import ▸ XML… | Works, captions attach to the right clip with the right role — but FCP asks *"replace existing items with matching names?"*. **Keep Both** makes a second project; **Replace** updates the existing one and discards anything edited since the export. | A dialog and a decision |
| Programmatic write-back | **Does not exist.** The SDK's host API is read-only and FCP's scripting dictionary has one `get` command. | — |

So the caption-file path wins on result, and the FCPXML path wins on fidelity (correct clip, correct
Korean role). Both are kept. Apple also documents a drag path — pasteboard types
`com.apple.finalcutpro.xml.v1-10` / `v1-9` / `com.apple.finalcutpro.xml` via
`NSPasteboardItemDataProvider` — which would remove the file dialog entirely; a developer-forum
report says it is rejected from inside an extension, and nobody from Apple answered. **Untested by
us. Test it the moment the panel exists.**

**A bug the real import found, now fixed and frozen as six tests:** our captions were red in the
timeline next to the editor's own. Final Cut Pro validates caption overlap **per language, not per
lane** — separate lanes did not save us. The writer now trims its captions clear of any existing
caption in the same language, skips one that would have to be split around theirs, never alters
what the editor wrote, and reports how many it skipped so a missing caption is never silent.

### M1 — the panel, and what the SDK settled (this branch)

The user installed the **Workflow Extensions SDK v1.0.3** (2026-09-09). Reading it answered the
project's biggest open question, and it is not the answer the spec hoped for:

> **The host API is read-only.** `FCPXHost` exposes the timeline playhead, the active sequence's
> name/start/duration/frameDuration/timecodeFormat, and library/event/project names and UIDs.
> There is **no API to send FCPXML — or anything — back into Final Cut Pro.** Spec §10's top rung
> (captions injected straight into the open project) is unreachable with the public SDK. Delivery
> has to be an FCPXML the user imports, or one dragged from the panel into the timeline.

Also learned, all from the SDK itself rather than documentation: the extension must **not** link
`ProExtensionHost` (headers only, no binary); it needs Hardened Runtime exceptions and an Apple
Events scripting-target entitlement; and **SDK v1.0.3 may not work under the Swift 6 runtime**,
so the extension target stays on Swift 5 while the packages remain Swift 6. All of it, with the
click path, is in `docs/XCODE_SETUP.md`.

- `FCPCaptionUI` — the panel as a package target, so it compiles, renders and tests without the
  extension existing. `PanelModel` is an explicit state machine (waiting / reading / ready /
  working / finished / failed), which is what keeps a real-looking value from flashing before the
  data arrives. 9 tests.
- `PanelPreview` — renders every state to PNG in both appearances. This is how a design change
  gets looked at before it ships, per `CLAUDE.md`.

### M0 and setup

- **Repo, rules, CI.** `CLAUDE.md` (ported from the sibling `shiftly` repo and adapted to
  Swift/Xcode/FCP), `.claude/settings.local.json`, `.gitignore`, MIT `LICENSE`, bilingual READMEs,
  GitHub Actions: `ci.yml` (build + test `FCPCaptionCore`) and `pages.yml` (deploy `site/`).
- **`FCPCaptionCore` package** — Swift 6 language mode, macOS 15, no UI/FCP dependency.
  - `CaptionBuilder` — the §8 Korean rules. 23 tests, all passing, run in ~1ms.
  - `SRTWriter`, `TranscriptWord`/`TranscriptSegment`/`Caption`, `TranscriptionEngine` protocol.
  - `WhisperKitEngine` — model download into `~/Library/Application Support/FCPCaption/models`,
    progress, cancellation. **Two local models, matching what the cloud engine lists:**
    `large-v3-turbo` (1.5 GB, the default — WhisperKit's own macOS recommendation) and `large-v3`
    (3.0 GB). Both use WhisperKit's `_turbo` folder, which is a macOS compute optimisation of the
    same weights rather than a different model. Identifiers verified against the repository, and
    both folder URLs answer 200.
- **`fcpcaption-cli`** — the M0 spike tool, and the fastest way to re-check quality later.
- **Landing page** — live at <https://jkh911208.github.io/fcp_ac/>, deployed from `site/` by
  `pages.yml`. Bilingual (KO default), reads the latest release from the GitHub API and links its
  `.dmg` asset; with no releases published it renders the honest "no build published yet" state.
- **Verified after push:** CI green on `macos-15`, Pages deployed, and a fresh `git clone` of the
  repo builds and passes all 23 tests — which is what caught a `.gitignore` `Models/` rule that had
  silently excluded `Sources/FCPCaptionCore/Models/` from the first commit.

## Not done / open questions

- **The Xcode side of M1.** No Xcode project, no app target, no extension target — that work is
  GUI-bound and waits on the user (below). The FCPXML layer underneath it is done.
- **Fixture (b) — what FCP actually hands the extension on drop — is still missing**, because
  getting it needs the extension to exist. The reader is written to tolerate that shape (clip with
  no project around it) but that tolerance is checked against a synthetic document, not a real one.
  Re-verify the moment the panel receives its first real drop.
- **Whether a two-line caption may be one text run** is unverified. FCP splits its own line breaks
  into separate runs; we write `line1\nline2` in a single run, which the DTD accepts. If FCP
  imports it wrong, mirror the fixture's run-per-line shape.
- **Chunking is not implemented.** `AudioExtractor` writes one file and WhisperKit windows it
  internally, which is fine on device. The spec's 5-minute chunks with 2s overlap are still needed
  for the OpenRouter engine (upload size) — build them when M4 makes the requirement concrete.
  A 60-minute clip has not been tried; 16 kHz mono float for an hour is ~230 MB in memory.
- **Caption quality is spot-checked, not measured.** One 24.5s real clip and one synthesized
  sample. The ±0.3s timing bar in the spec's definition of done has not been measured against
  anything. Needs the 1/15/60-minute clips.
- **The caption language of an imported `.srt` is unverified.** The SRT path put captions on the
  timeline with no complaint, but nothing yet confirms they arrive with the Korean caption role
  rather than a default. Writing `.itt` instead would let us state the language — and that needs a
  real `.itt` exported from FCP first, the same way the FCPXML schema did.
- **M2 is the project's real risk** and is untouched: can a Workflow Extension attach captions to
  clips in an *already-open* project via FCPXML import? Fallback ladder in spec §10.

## Next

1. ~~Fixture (a), the FCPXML reader/writer, audio extraction, the pipeline, the panel UI~~ — done.
2. **Blocked on the user:** create the Xcode project and the extension target — `docs/XCODE_SETUP.md`
   steps 1–3. Five minutes of clicking; everything after it is code.
3. Then, in order: the entitlement and Info.plist edits (agent, plist files not GUI), the view
   controller hosting `PanelView`, and a first real drop — which captures fixture (b) and answers
   what the pasteboard actually carries.
4. M2 is now half-answered by the SDK headers. What remains is only *which* delivery path works:
   dragging FCPXML from the panel into the timeline, or opening the file for import.

## Blocked on the user

| What | Needed for | Why it can't be done here |
|---|---|---|
| ~~FCPXML fixture (a)~~ | — | **Done** — provided 2026-09-09, committed as `Fixtures/caption_one_clip.fcpxml` |
| FCPXML fixture (b) — what FCP hands the extension on drop | M1 | Same; and it needs the extension running |
| Korean test clips: 1 / 15 / 60 minutes | M0 sign-off, M3 | Real speech, real accents, real noise |
| Xcode target/entitlement/signing setup | M1, M5 | GUI-only work — per spec §14 it stays with the user |
| Apple Developer Program membership | M5 only | Notarization |
| OpenRouter API key | M4 only | The user's own key, stored in Keychain |
