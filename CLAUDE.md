# CLAUDE.md

Guidance for AI agents working in this repo. Keep changes small, verify them, and work on a branch.

## Language

- **Always respond in Korean (한국어)** when communicating with the user in chat.
- Keep code, comments, commit messages, PR titles/bodies, and docs in English.

## What this is

**FCPCaption** — a Final Cut Pro Workflow Extension that puts Korean subtitles on the FCP
timeline. The user drags a clip from the FCP timeline onto the sidebar panel; the app extracts
the audio, transcribes it (on-device WhisperKit or the user's own OpenRouter key), splits it
into Korean caption units, and writes the captions back into FCP's caption lane.

Free and MIT-licensed, distributed as a signed + notarized `.dmg` on GitHub Releases. **No
server, no telemetry.** In local mode the app makes no network calls at all except model downloads.

The full product spec — scope, non-goals, caption rules, milestones — is
**[FCP_CAPTION_SPEC.md](FCP_CAPTION_SPEC.md)**. Read it before any non-trivial work. Current
state, blockers and next steps live in **[PROGRESS.md](PROGRESS.md)**; keep it updated so a
session that dies mid-task can be resumed from that file alone.

## Repository map

- `FCPCaptionCore/` — Swift Package. All testable logic, **no UI and no FCP dependency**:
  `FCPXML/` (reader + writer), `Audio/` (AVFoundation extraction + chunking),
  `Transcription/` (`TranscriptionEngine` protocol, WhisperKit + OpenRouter engines),
  `Captioning/` (`CaptionBuilder`, the Korean splitting rules), `Settings/` (UserDefaults + Keychain).
- `FCPCaption/` — SwiftUI host app (macOS).
- `FCPCaptionExtension/` — the Workflow Extension appex. The real UI lives here.
- `Tools/fcpcaption-cli/` — headless CLI for spikes and manual timing checks (file → transcript → `.srt`).
- `Fixtures/` — **real** FCPXML exported from FCP, plus self-recorded audio. Never invented by hand.
- `docs/` — `SPIKE_IMPORT.md`, `MANUAL_TEST.md`, `XCODE_SETUP.md`, `RELEASE.md`.

## Build / test / lint

Run from the worktree you're editing.

- **Core package:** `cd FCPCaptionCore && swift build && swift test`
- **App + extension:** `xcodebuild -scheme FCPCaption -destination 'platform=macOS,arch=arm64' build`
- **All tests:** `xcodebuild test -scheme FCPCaption -destination 'platform=macOS,arch=arm64'`
- **Never hand a build failure back to the user.** Run `xcodebuild` yourself and fix the compile
  errors; that is not a GUI task.
- Apple silicon only: every target sets `ARCHS = arm64` and `EXCLUDED_ARCHS = x86_64`. Do not
  produce universal binaries — WhisperKit is CoreML/ANE-based and Intel is out of scope.
- Minimum deployment target **macOS 15**. Don't raise it to whatever this Mac happens to run.

## Testing — add tests for every new feature

`FCPCaptionCore` must be unit-testable with no UI, no FCP and no network. **A feature isn't done
until its new code paths are covered.** When you add or change code, add the matching tier:

- **`CaptionBuilder`** (the §8 Korean splitting rules) → a **fixture-based** table test. Word-timestamp
  arrays in, expected captions out. At least 10 Korean cases: silence gaps, sentence punctuation,
  commas, over-length lines, min/max duration clamping, overlap trimming, and the segment-only
  fallback (engines that return no word timestamps). This module is where the product's quality
  lives; treat a missing case as a bug.
- **`FCPXMLReader` / `FCPXMLWriter`** → round-trip against a **real fixture** in `Fixtures/`
  (parse → build → parse, assert stable). Never assert against XML you wrote from memory.
- **`AudioExtractor`** → chunk-offset math: a transcript from chunk N must land at
  `chunkStart + wordTime`, and the 2s overlap must not duplicate words.
- **`OpenRouterEngine`** → `URLProtocol` mock. Assert the request body/headers and the parsing of
  `verbose_json`, including an error response. **Never let a test hit the real API.**
- **Freeze every bug you fix as a test** that would have failed before the fix.
- Manual, on-device checks (real FCP, real clips) belong in `docs/MANUAL_TEST.md` and are run by
  the user — they don't replace the automated tier above.

## Working conventions (important)

- **Always work in a git worktree / feature branch — never edit the main working tree.** Read, edit,
  and build in the worktree path.
- **`/Users/james/repo/fcp_ac` is the main working tree. It stays on `main`, and on the LATEST
  `main`. Never `git checkout` anything else there, and never commit there.** It is the reference
  copy every other worktree is cut from and compared against; the moment it sits on a feature
  branch it is a trap that nothing points at — in the sibling `shiftly` repo exactly that went
  unnoticed for three weeks, and scripts run from that stale tree silently skipped their guards.
  If you find it on another branch, put it back (`git checkout main && git pull --ff-only`) before
  doing anything else, and tell the user what was on it.
- **Switch branches by cutting a worktree, never by `git checkout`.** A checkout rewrites the tree
  you are standing in — and with Xcode that means DerivedData rebuilds and a running FCP extension
  pointing at a stale build. A worktree costs a directory and leaves everything open where it was.
  `git checkout` is for putting the main tree BACK on `main`, and for nothing else.
- **Confirm `main` is current BEFORE cutting a worktree, and branch from `origin/main`.**
  `git fetch origin main`, then `git worktree add .worktrees/<name> -b <branch> origin/main`.
  Branching from the local `main` ref inherits whatever it last happened to be; naming
  `origin/main` after a fetch cannot. (Before a remote exists, branch from local `main` — and say so.)
- **Delete the worktree and its local branch once the PR is merged or closed.** They are free to
  make and not free to keep: a long list is one more place to pick the wrong tree from, and each
  one strands its own Xcode DerivedData (gigabytes). Never remove a worktree holding uncommitted
  work, an open PR, or unpushed commits. After deleting, if you were reclaiming disk, report the
  number from `df` — not from what you deleted (APFS local snapshots can hold the blocks;
  `tmutil thinlocalsnapshots / 100000000000 4` releases them).
- **After a merge, bring the main tree back up to date.** `git -C /Users/james/repo/fcp_ac pull
  --ff-only` — every rule above assumes it is current.
- **Run repo scripts from the worktree, by their worktree path.** `./scripts/foo.sh` resolves
  against the current directory, so a script invoked from the wrong tree is that tree's version of
  it. Same rule as editing and building.
- **A guard that could not run is a FAILURE, not a pass.** When a check cannot reach its subject,
  say so and stop; never fall through to the reassuring branch. Real examples from the sibling repo,
  all of which printed a calm sentence and proceeded: a `| grep -q .` pipeline reporting SIGPIPE as
  "nothing found", a pathspec resolved against the wrong directory that matched nothing, and a
  checker exiting 0 on an empty directory. Write the skip branch so it has to PROVE the subject is
  absent — and if the situation is impossible, make it an error. Same rule in Swift: a `catch` that
  swallows and returns an empty array is a guard that could not run.
- **Rebase onto the latest `main` before opening the PR.** `git fetch origin main && git rebase
  origin/main`, resolve conflicts, then `gh pr create`. A PR opened from a branch already behind
  gets CI results for a tree nobody will merge.
- **When the code is done, open the PR — don't ask first.** As soon as it builds and its tests pass,
  push the branch and open the PR without checking in. CI takes a while, so an early PR is free
  feedback, and a PR is not a merge — it changes nothing until someone merges it.
- **Merge to `main` only when the feature fully works and has been tested in real FCP.
  Never merge on your own — wait for an explicit instruction**, even when the PR is green.
- **Releases are outward-facing — confirm with the user before running them.** Publishing a GitHub
  Release, uploading a notarized dmg, or pushing a tag is never automatic. Signing/notarization
  detail lives in `docs/RELEASE.md`.
- **Commit at the end of every milestone.** English message, one-line summary + body. And update
  `PROGRESS.md` in the same commit — what works, what doesn't, what's next, what's blocked and why.
- **Design/UI changes need a rendered before/after preview first.** Before writing code for a
  visual change, render an actual before/after image and get the user's explicit confirmation. Text
  or ASCII approximations (dashes, percentage bars) do not count — it must be a real rendered image.
  For SwiftUI panels, an Xcode preview screenshot counts.
- **No placeholder-before-load flicker — never paint a real-looking value that then flips once async
  data arrives.** Any view fed by an async `Task` (a `@Published`/`@State` set after an `await`, a
  `.task {}` modifier) must distinguish "not loaded yet" from a genuine value/empty/zero. The smell
  is a first paint that shows a meaningful default and then visibly changes — e.g. a model list that
  starts empty and means "none installed", a `0 MB` size, a "이 Mac에서" engine label before settings
  load. Fix: carry an explicit loaded flag, **set it on success AND failure** (`defer`, so a failed
  load can't spin forever), and until it's true render a spinner, a neutral blank, or nothing — then
  snap straight to the real value. In a 300pt sidebar panel this flicker is the whole screen.

## Project rules (from the spec — these bind every session)

- **Xcode GUI-only work is the user's, not yours.** Adding targets, entitlements, capabilities,
  signing identities, Developer account linking, the extension's `Info.plist` point-of-extension —
  do not attempt these. Tell the user exactly what to click, step by step, in Korean, then **wait**
  until they say it's done. Everything else (writing Swift, `xcodebuild`, fixing compile errors,
  editing `project.pbxproj` when it's genuinely safe) is yours. Keep `docs/XCODE_SETUP.md` as the
  running record of what has been set up by hand, so a fresh clone can be reproduced.
- **Never guess an Apple API or the FCPXML schema.** Workflow Extensions (ProExtension) and FCPXML
  captions are the two places this project fails silently. Verify against Apple's official
  documentation/sample code, or against **actual FCP output** in `Fixtures/`. If you can't verify,
  ask — don't ship a plausible-looking guess.
- **Fixtures before FCPXML code.** The `<caption>` structure, the role string (`iTT?captions.ko`),
  the rational time format and the frame-alignment rounding all come from a real export, not from
  memory. Rounding policy must be explicit and tested.
- **Version strings are echoed, never hardcoded.** The reader records the FCPXML version of the
  document it received and the writer returns that same version.
- **No ffmpeg, no GPL code or binaries, ever.** Audio is AVFoundation only. The only third-party
  SPM dependency is **WhisperKit**. Adding a second dependency needs the user's approval.
- **Never copy or reference third-party products** (mCaptionsAI etc.) — not their code, assets,
  names, or UI.
- **API keys live in the Keychain only.** Never in `UserDefaults`, never in a log line, a crash
  report, an error message, or the UI. Personal data (transcript text, media paths) stays out of
  the default log level; use `os.Logger` with privacy annotations.
- **No over-abstraction and no hooks for out-of-scope features.** Translation, diarization, styled
  title templates and a subtitle editor are explicitly out of v1 — don't leave seams for them. The
  two sanctioned abstractions are the `TranscriptionEngine` protocol and an injectable base URL on
  the OpenAI-compatible engine.
- **Cancellation is a feature, not a nicety.** Every long operation is a cancellable `Task`;
  cooperative cancellation plus the engine's own `cancel()`. UI work on `@MainActor`, transcription
  off it. Prefer Swift 6 strict concurrency.
- **Every user-facing error is a Korean sentence a human can act on**, plus a retry affordance.
  "Error -12345" is not an error message.

## Milestones

The table in **[FCP_CAPTION_SPEC.md §13](FCP_CAPTION_SPEC.md)** is the plan of record: M0 spike →
M1 extension shell → M2 import spike → M3 local E2E → M4 cloud engine → M5 release.

**M2 is the project's real risk** — whether a Workflow Extension can attach captions to clips in an
already-open project via FCPXML import. Work the fallback ladder in §10 top-down, take the first
rung that actually works, and write down what you tried in `docs/SPIKE_IMPORT.md`. Don't build M3
on an assumption about M2.
