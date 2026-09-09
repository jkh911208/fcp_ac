# PROGRESS

Running state of the project. Read this first after a break — it is meant to be enough on its own.
Plan of record: [FCP_CAPTION_SPEC.md](FCP_CAPTION_SPEC.md). Working rules: [CLAUDE.md](CLAUDE.md).

**Last updated:** 2026-09-09 · **Current milestone:** M1 in progress (FCPXML layer done).
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

### M0 and setup

- **Repo, rules, CI.** `CLAUDE.md` (ported from the sibling `shiftly` repo and adapted to
  Swift/Xcode/FCP), `.claude/settings.local.json`, `.gitignore`, MIT `LICENSE`, bilingual READMEs,
  GitHub Actions: `ci.yml` (build + test `FCPCaptionCore`) and `pages.yml` (deploy `site/`).
- **`FCPCaptionCore` package** — Swift 6 language mode, macOS 15, no UI/FCP dependency.
  - `CaptionBuilder` — the §8 Korean rules. 23 tests, all passing, run in ~1ms.
  - `SRTWriter`, `TranscriptWord`/`TranscriptSegment`/`Caption`, `TranscriptionEngine` protocol.
  - `WhisperKitEngine` — model download into `~/Library/Application Support/FCPCaption/models`,
    progress, cancellation. Model identifiers verified against the Hugging Face repo listing.
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
- **`AudioExtractor` is not written.** M0 hands the file straight to WhisperKit, which loads and
  windows audio itself. The spec's 5-minute chunking with 2s overlap is still needed for the
  OpenRouter engine (upload size) and possibly for progress granularity on long clips — decide
  when M3/M4 make the requirement concrete, rather than building it speculatively now.
- **Caption quality is only smoke-tested.** The one sample was synthesized speech, which is
  cleaner than real recordings. Needs the real 1/15/60-minute Korean clips (see Blocked).
- **M2 is the project's real risk** and is untouched: can a Workflow Extension attach captions to
  clips in an *already-open* project via FCPXML import? Fallback ladder in spec §10.

## Next

1. ~~Fixture (a) and the FCPXML reader/writer~~ — done on `m1-fcpxml`.
2. Create the Xcode project: host app + Workflow Extension target (**user does this in the GUI**;
   step-by-step to be written into `docs/XCODE_SETUP.md` as it happens).
3. Panel shows the dropped clip's name and duration — M1's completion bar. Capture the FCPXML it
   receives as fixture (b) the first time it works.
4. Then M2, the import spike (spec §10), before any of M3.

## Blocked on the user

| What | Needed for | Why it can't be done here |
|---|---|---|
| ~~FCPXML fixture (a)~~ | — | **Done** — provided 2026-09-09, committed as `Fixtures/caption_one_clip.fcpxml` |
| FCPXML fixture (b) — what FCP hands the extension on drop | M1 | Same; and it needs the extension running |
| Korean test clips: 1 / 15 / 60 minutes | M0 sign-off, M3 | Real speech, real accents, real noise |
| Xcode target/entitlement/signing setup | M1, M5 | GUI-only work — per spec §14 it stays with the user |
| Apple Developer Program membership | M5 only | Notarization |
| OpenRouter API key | M4 only | The user's own key, stored in Keychain |
