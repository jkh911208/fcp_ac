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

### M2 — settled by trying every route in real Final Cut Pro (2026-09-09)

**The caption file wins.** Save an `.itt`, then **File ▸ Import ▸ Captions…**: the captions land on
the project already open, in Korean, with nothing duplicated. The panel offers that first.

| Route | What happened |
|---|---|
| **iTT file + File ▸ Import ▸ Captions…** | ✅ Lands on the open timeline. `Format iTT \| Language Korean`. No dialog, no duplication |
| SRT file, same import | Works, but arrives tagged **English** — SubRip has nowhere to record a language |
| FCPXML + File ▸ Import ▸ XML… | Imports, but brings a **copy of the event and project** into the library ("9-9-26 1"). Import means bringing items in; no dialog choice avoids that |
| FCPXML by Apple Event `open` | Works — after a `temporary-exception.apple-events` entitlement. The read-only `library.inspection` scripting group is not enough and fails with "A privilege violation occurred" |
| Caption file by Apple Event `open` | ❌ Final Cut Pro refuses it. It declares no caption UTIs |
| Caption file dragged from Finder | ❌ |
| FCPXML dragged from the panel | Not built. Apple documents it and a shipping plugin uses it, but the caption-file route was good enough — **the user's call, and the reason there is no drag code here** |

Programmatic write-back does not exist at any point: the SDK's host API is read-only and Final Cut
Pro's scripting dictionary has one `get` command.

**Three bugs this found, each invisible until a real project hit it:**
- Captions were appended to the end of a clip. Apple's DTD orders a clip's children and `caption`
  is an anchored item that must precede markers, `audio-channel-source`, filters and metadata. The
  reference export had none of those; a clip with a Dialogue-1/Dialogue-2 configuration does, and
  FCP rejected the entire import.
- Every caption carried a trailing `<br/>`, copied from the reference export — where it existed
  because that caption's editor had typed a newline. It added an empty third line, past FCP's
  two-line limit, and drew every caption **red**.
- The save panel was handed a name that already had its extension, so it offered
  `IMG_2194.itt.itt`.

### Transcription is not repeatable, and that is the right trade (2026-09-09)

Running the same 18-minute clip twice through the same model produced transcripts only **53.9%**
alike — a bigger gap than between large-v3 and turbo (60.2%). **Every quality comparison made
before this was reading noise, including one that nearly changed the default model.**

The cause, isolated on a 3-minute clip with each setting run twice:

| Setting | Time | Same output twice? | Captions |
|---|---|---|---|
| 16 workers, 5 retries (WhisperKit default) | 22.3s / 23.0s | no — 91.8% alike | 47 / 41 |
| 1 worker, 5 retries | 18.9s / 21.2s | no — 82.2% alike | 32 / 46 |
| 16 workers, **0 retries** | 14.8s / 14.0s | **yes — byte-identical** | 32 / 32 |

It is the **temperature fallback**, not concurrency: above zero temperature the decoder samples,
and each window prompts the next, so one sampled token propagates. Fewer workers made it worse.
WhisperKit samples with `Float.random(in: 0..<1)` and exposes no seed, so there is no way to have
both without forking the dependency.

**Turning the retries off is not the answer.** In that clip the two settings agreed exactly for
117 seconds, and then the no-retry run went almost silent for the remaining minute — a third of
the clip lost, which is also why it looked faster. The retries recover a window whose decode has
collapsed; without them the collapse is permanent.

So the default keeps them, and both parameters are exposed in Settings with the trade-off written
out. A caption that shifts between runs is a nuisance; a minute of missing dialogue is a broken
subtitle track.

### Local model speed, measured on 18m20s (2026-09-09)

Nothing else running, model already downloaded and compiled:

| | large-v3 | large-v3-turbo |
|---|---|---|
| Time | 456s (0.40× real time) | **118s (0.11×)** |
| Download | 3.0 GB | 1.5 GB |
| First run also | ~10 min Neural Engine compile, 6.3 GB RAM | shorter |

**Turbo is 3.9× faster, and that number is solid.** Which of them transcribes Korean better is
**not** something these measurements can answer — the run-to-run variance swamps the difference.
large-v3 stays the default on the strength of the model card (turbo is large-v3 with its decoder
pruned from 32 layers to 4, for "minor quality degradation"), not on the strength of anything
measured here. Settling it properly would need a reference transcript and several runs per model.

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
- **Timing accuracy is still unmeasured.** The spec's ±0.3s bar (§15.2) has not been checked
  against anything; that needs the playhead and a human ear, and it is in `docs/MANUAL_TEST.md`.
  Transcription quality itself is now measured on 18 minutes — see the model comparison above.
- **A 60-minute clip has not been tried.** Extrapolating, large-v3 would take ~22 minutes and hold
  about 230 MB of audio in memory.
- ~~The caption language of an imported `.srt` is unverified.~~ **It arrives as English.** Final
  Cut Pro's own caption inspector says `Format SRT | Language English`, because SubRip has nowhere
  to record a language. Fixed by writing **iTT** instead: `Fixtures/caption_korean.itt` is a real
  FCP export, and `ITTWriter` reproduces it — `xml:lang` on the root, SMPTE timecodes counted in
  nominal frames, the 1000/1001 pulldown multiplier. The CLI now writes an `.itt` next to the
  FCPXML, which is the file that reaches the already-open project with no dialog.
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

**M4 (OpenRouter engine, Keychain, Settings) is deferred** — the user's call, 2026-09-09. The
`TranscriptionEngine` protocol and the injectable base URL stay as the spec sanctions them, but
nothing else is built for it. Order is now M3 (local end to end in the panel) → M5 (release).
Costs were checked while the question was open, and they are not the reason to hurry: an 18-minute
clip is about **1 cent** on `openai/whisper-large-v3` and a third of that on turbo. The real case
for the cloud engine is that it needs no 3 GB download, no ten-minute Neural Engine compile and no
6 GB of RAM on first run.

## Blocked on the user

| What | Needed for | Why it can't be done here |
|---|---|---|
| ~~FCPXML fixture (a)~~ | — | **Done** — provided 2026-09-09, committed as `Fixtures/caption_one_clip.fcpxml` |
| FCPXML fixture (b) — what FCP hands the extension on drop | M1 | Same; and it needs the extension running |
| Korean test clips: 1 / 15 / 60 minutes | M0 sign-off, M3 | Real speech, real accents, real noise |
| Xcode target/entitlement/signing setup | M1, M5 | GUI-only work — per spec §14 it stays with the user |
| Apple Developer Program membership | M5 only | Notarization |
| OpenRouter API key | M4 only | The user's own key, stored in Keychain |
