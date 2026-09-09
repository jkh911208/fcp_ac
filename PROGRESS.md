# PROGRESS

Running state of the project. Read this first after a break — it is meant to be enough on its own.
Plan of record: [FCP_CAPTION_SPEC.md](FCP_CAPTION_SPEC.md). Working rules: [CLAUDE.md](CLAUDE.md).

**Last updated:** 2026-09-09 · **M0–M3 and M5 are done. M4 is deferred by the user.**
The extension runs in Final Cut Pro's sidebar and the whole round trip has been verified by hand:
drag a project in, get Korean captions on the timeline, as captions or titles or both, styled.
Signed, notarized and published from this Mac; GitHub only hosts the file.

**Scope change (2026-09-09, user's decision), now shipped:** the panel offers **captions and
titles**, not just captions. Spec §4.2 puts styled title templates out of v1 — reversed, because
Final Cut Pro's caption inspector offers no font control at all while its Subtitle *title*
template offers every one. Both are wanted and they coexist on one timeline, so "both" is a real
option and not a compromise. **Final Cut Pro does render the `text-style` written into a caption**
— 40pt Helvetica in yellow came through — it simply gives no way to change it afterwards; what
titles add is editability inside FCP. The title effect `uid` came from a real export
(`Fixtures/title_subtitle.fcpxml`), never from memory.
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

### M2 and M3 — both routes work end to end (2026-09-09)

Every step below was run in real Final Cut Pro, on a real project.

**Caption file — the everyday route.** Save an `.itt`, then **File ▸ Import ▸ Captions…**: the
captions land on the project already open, tagged Korean, no dialog and nothing duplicated. SRT
does the same but arrives tagged **English**, because SubRip has nowhere to record a language.

**FCPXML — the route that carries styling.** Drag the project onto the panel, transcribe, **Final
Cut Pro로 보내기**, choose the library, **Replace** — and the project the editor was working in is
updated in place. Captions, titles, or both, with every text attribute Final Cut Pro renders.

Two dialogs on that path cannot be removed, and both are Apple's design:
- the **Open Library** dialog is documented as always appearing for an Apple Event import;
- **Replace** is the choice FCP offers when the incoming items match existing ones — which is
  exactly what we want it to notice.

What made the difference between "a copy appears" and "your project is updated" was wrapping the
project back into its own event and library, read from `FCPXHost`. That, in turn, needed the
**automation permission**: without it every host property returns nil, with no error and nothing in
any log. Two fixes were attempted against that silence before a file-based trace named the cause in
one line. `os_log` from this extension does not reach `log show` at all.

**Programmatic write-back does not exist** at any point: the host API is read-only and Final Cut
Pro's scripting dictionary has one `get` command. A caption file cannot be delivered by `open`
either — FCP refuses it, declaring no caption UTIs.

**Bugs this found, none of which a test would have caught first:**
- captions appended after `audio-channel-source` broke the DTD's child order, and FCP rejected the
  whole import;
- a trailing `<br/>`, copied from the reference export, added an empty third line and turned every
  caption red;
- a clip's `start` is a **timecode**, so a DJI file shot at 17:12 asked AVFoundation for the
  61,920-second mark of an 1,101-second recording;
- titles are measured on **two different grids at once** — position on the clip's rate, length on
  the sequence's — which took two rounds to see because the fixture was only read halfway;
- reopening the panel does not restart the extension, so anything asked once in `viewDidLoad` was
  never asked again.

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
- ~~**M2 is the project's real risk** and is untouched.~~ **Answered** — both routes work; see
  "M2 and M3" above. The `.itt` route reaches the already-open project with no dialog at all.

### M5 — the release (2026-09-09)

`Tools/package_release.sh` builds Release, signs the appex before the app that contains it,
verifies the signature, refuses to continue if library validation crept back onto the extension
(the SDK does not work with it), builds and signs the dmg, notarizes, staples, and re-checks the
result the way Gatekeeper will. With a version argument it also publishes to GitHub Releases —
that step is file hosting only. The build has to happen on this Mac because Apple's Workflow
Extensions SDK cannot be installed on a hosted runner, so the tag-triggered CI build the user
asked about is not possible; `.github/workflows/ci.yml` runs the package tests and nothing more.

Signing identity, team id and notary profile all come from the environment, so no secret is ever
written into the repo. What exists on this Mac: `Developer ID Application: Gyuhyong Jeon
(S597P43HS4)` and a `notarytool store-credentials` profile named `fcpcaption`.

Two bugs, both found by actually running it rather than reading it.

**The script could never have run on this Mac.** Under `set -u`, macOS's bash 3.2 treats an empty
array's `"${arr[@]}"` as an *unbound variable*, so the optional-keychain argument aborted every
local release at the signing step. Guarded with `${arr[@]+"${arr[@]}"}` and checked in bash 3.2
itself, both empty and non-empty. This is "a guard that could not run is a FAILURE" wearing a
different hat: the empty case was the normal case, and it had never been exercised.

**v0.1.0 stapled the dmg but not the app inside it** (found by installing the published dmg and
running `stapler validate` on `/Applications/FCPCaption.app`, which said it had no ticket). A
ticket belongs to one artifact, and the app is the part that survives installation — so Gatekeeper
had to ask Apple over the network at first launch. Online that is invisible, which is why it
passed every check made at the time; offline or behind a firewall it blocks the first launch of a
brand-new app. **v0.1.1** notarizes and staples the app first, builds the dmg from the stapled app,
and refuses to continue if the copy into the image lost the ticket. `cp -R` is now `ditto` for the
same reason. The lesson is the one this file keeps relearning: check the artifact a user ends up
with, not the one the script last touched.

## Next

- **M4 (OpenRouter engine, Keychain, Settings)** if the user ever wants it — see below.
- **Transcription results are lost if the panel closes** or the extension is reinstalled. Nothing
  is persisted between a run and the save. On a 20-minute clip that is 20 minutes thrown away.
  This is the first thing worth fixing.
- **A 60-minute clip has never been tried**, on any route.
- Whether YouTube reads captions embedded in an uploaded video is undocumented and untested; the
  reliable answer remains uploading the `.srt` as a subtitle track.

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
| ~~Xcode target/entitlement/signing setup~~ | — | **Done** — `docs/XCODE_SETUP.md` is the record |
| ~~Apple Developer Program membership~~ | — | **Done** — Developer ID cert + `fcpcaption` notary profile exist on this Mac |
| OpenRouter API key | M4 only | The user's own key, stored in Keychain |
