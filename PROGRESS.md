# PROGRESS

Running state of the project. Read this first after a break — it is meant to be enough on its own.
Plan of record: [FCP_CAPTION_SPEC.md](FCP_CAPTION_SPEC.md). Working rules: [CLAUDE.md](CLAUDE.md).

**Last updated:** 2026-09-09 · **Current milestone:** M0 done, M1 next.

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

- **Repo, rules, CI.** `CLAUDE.md` (ported from the sibling `shiftly` repo and adapted to
  Swift/Xcode/FCP), `.claude/settings.local.json`, `.gitignore`, MIT `LICENSE`, bilingual READMEs,
  GitHub Actions: `ci.yml` (build + test `FCPCaptionCore`) and `pages.yml` (deploy `site/`).
- **`FCPCaptionCore` package** — Swift 6 language mode, macOS 15, no UI/FCP dependency.
  - `CaptionBuilder` — the §8 Korean rules. 23 tests, all passing, run in ~1ms.
  - `SRTWriter`, `TranscriptWord`/`TranscriptSegment`/`Caption`, `TranscriptionEngine` protocol.
  - `WhisperKitEngine` — model download into `~/Library/Application Support/FCPCaption/models`,
    progress, cancellation. Model identifiers verified against the Hugging Face repo listing.
- **`fcpcaption-cli`** — the M0 spike tool, and the fastest way to re-check quality later.
- **Landing page** — `site/index.html`, bilingual, reads the latest release from the GitHub API
  (currently renders the honest "no build published yet" state, since there are no releases).

## Not done / open questions

- **Everything FCP-facing.** No Xcode project, no app target, no extension target, no FCPXML
  reader or writer. That is M1 and it starts with fixtures (below).
- **`AudioExtractor` is not written.** M0 hands the file straight to WhisperKit, which loads and
  windows audio itself. The spec's 5-minute chunking with 2s overlap is still needed for the
  OpenRouter engine (upload size) and possibly for progress granularity on long clips — decide
  when M3/M4 make the requirement concrete, rather than building it speculatively now.
- **Caption quality is only smoke-tested.** The one sample was synthesized speech, which is
  cleaner than real recordings. Needs the real 1/15/60-minute Korean clips (see Blocked).
- **M2 is the project's real risk** and is untouched: can a Workflow Extension attach captions to
  clips in an *already-open* project via FCPXML import? Fallback ladder in spec §10.

## Next (M1)

1. Get the two FCPXML fixtures from real FCP (see Blocked) and commit them under `Fixtures/`.
2. Create the Xcode project: host app + Workflow Extension target (**user does this in the GUI**;
   a step-by-step is written when we get there, and recorded in `docs/XCODE_SETUP.md`).
3. `FCPXMLReader` against the real fixture — media URL, clip id, offset/start/duration, frame rate,
   document version echoed back rather than hardcoded.
4. Panel shows the dropped clip's name and duration. That is M1's completion bar.

## Blocked on the user

| What | Needed for | Why it can't be done here |
|---|---|---|
| FCPXML fixture (a) — a project with one Korean caption, exported as FCPXML | M1/M3 | Only real FCP output can settle the `<caption>` schema and role string |
| FCPXML fixture (b) — what FCP hands the extension on drop | M1 | Same; and it needs the extension running |
| Korean test clips: 1 / 15 / 60 minutes | M0 sign-off, M3 | Real speech, real accents, real noise |
| Xcode target/entitlement/signing setup | M1, M5 | GUI-only work — per spec §14 it stays with the user |
| Apple Developer Program membership | M5 only | Notarization |
| OpenRouter API key | M4 only | The user's own key, stored in Keychain |
