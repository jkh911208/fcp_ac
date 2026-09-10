# Manual test checklist

What the automated tests cannot reach: Final Cut Pro itself. Run this before a release, and after
any change to the panel, the writer, or delivery.

Record the date and the result. A checklist with no dates is a checklist nobody ran.

## Setup

- Apple silicon Mac, macOS 15+, Final Cut Pro 12.x
- `/Applications/FCPCaption.app` installed (only one copy anywhere — the SDK release notes warn
  that several copies get discovered and which one wins is undefined)
- Korean test clips of about **1 minute**, **15 minutes** and **60 minutes**

## 1. The panel appears and shows its settings

- [ ] **Window ▸ Extensions ▸ FCPCaption** exists
- [ ] Clicking it opens the panel
- [ ] The panel is legible at the FCP sidebar's narrowest width
- [ ] It follows the system appearance in both light and dark

## 2. A dropped project

- [ ] Dragging a project from the browser onto the panel shows its clips and total duration
- [ ] The name matches the clip, not the media file, when they differ
- [ ] Dropping something that is not a clip gives a Korean message, not a hang
- [ ] `/usr/bin/log show --last 5m --predicate 'subsystem == "com.jkh911208.FCPCaption"'` names
      the pasteboard types that arrived — **record them**, they are still undocumented.
      Use the full path: `log` is also a zsh builtin, and the builtin fails with "too many
      arguments" while looking, at a glance, like a query that simply found nothing.

### 2a. The drop must survive a *fast* release

This is the one that regressed once, and no unit test can hold it: the drag path is AppKit
callbacks, not package code. **Drop with a quick flick — press, drag, release immediately** —
rather than hovering first. Repeat five times on a panel that has just been opened.

- [ ] Every one of the five is picked up
- [ ] For each, the log shows `drag entered` **followed by** `using pasteboard data`. A `drag
      entered` with nothing after it is the failure: `performDragOperation` was never called
- [ ] In `host-trace.txt` (see below), no `took N ms` line that immediately follows a drag is
      more than a few hundred ms

Why it matters: `HostContext.refresh()` makes synchronous calls into Final Cut Pro, which is
itself blocked waiting for the drag callback to return. Measured at ~2000 ms when it resolves a
sequence, and a mouse release inside that window loses the drop entirely. Anything slow must stay
out of `draggingEntered` and `performDragOperation`. The trace is at:

```
~/Library/Containers/com.jkh911208.FCPCaption.Extension/Data/Library/Application Support/FCPCaption/host-trace.txt
```

Note the cruel shape of this bug: it only appears when the host lookup **succeeds**. A panel that
cannot read the project at all drops perfectly.

## 2b. Settings are in the panel, not behind a button

- [ ] The model, language, form, style and splitting rules are all visible by scrolling the panel
- [ ] Changing one and closing the panel keeps the change on reopen
- [ ] During a run, the settings are visibly dimmed and cannot be changed

## 2c. Reporting a problem

- [ ] **문제 신고** at the bottom of the panel offers a save panel, writes a zip, and reveals it
- [ ] The zip holds `report.md`, `log.txt` and `host-trace.txt`
- [ ] `report.md` names this Mac, this macOS build, and **Final Cut Pro's version**
- [ ] It contains no name, serial number, hostname or file path
- [ ] A GitHub issue opens with the environment table already in the body
- [ ] After a failure, **이 오류 신고하기** puts the error message into the report

## 2d. A project with awkward clips

Use a real edit, not a single clip on a spine.

- [ ] A project containing a retimed (slow-motion) clip finishes, and names that clip under
      "클립 N개는 자막을 만들지 않았습니다"
- [ ] A muted clip is listed there too, not captioned
- [ ] **Connected clips are captioned** — audio synced under the picture on lane -1 is dialogue and
      must not be skipped. Count the captions against the shots that actually have speech
- [ ] One bad clip does not lose the run: the rest are captioned

## 3. Transcription — 1 minute

- [ ] Progress advances through 오디오 추출 → 음성을 전사하는 중, and never goes backwards
- [ ] 취소 stops it promptly and returns to the clip, not to an empty panel
- [ ] Running it again after a cancel works

## 4. The captions themselves

- [ ] Korean text is correct enough to read
- [ ] **Timing is within ±0.3s of the speech** (spec §15.2) — check three captions with the playhead
- [ ] Lines are at most 18 characters, captions at most 2 lines
- [ ] No caption is shorter than 1s or longer than 6s
- [ ] Nothing is red in the timeline (red means Final Cut Pro found overlapping captions)
- [ ] Captions the editor typed by hand are untouched, and the panel says how many of ours it
      skipped to avoid them

## 5. Delivery

- [ ] The captions arrive in Final Cut Pro with the **Korean** caption role, not English
      (Inspector ▸ caption ▸ Language, or File ▸ Export Captions… and look at the role list)
- [ ] The project the editor was working in is still there

## 6. Long clips

- [ ] 15 minutes finishes, and the whole clip is captioned — not just the first stretch
- [ ] 60 minutes finishes. **Watch memory**: audio is held as 16 kHz mono, about 230 MB an hour,
      and the first run of a model also compiles for the Neural Engine (6+ GB, minutes)
- [ ] Captions near the end are still in sync — a drift here means chunk offsets are wrong

## 7. Failure states

- [ ] Airplane mode, model not yet downloaded → a Korean message explaining what to do
- [ ] A clip with no audio → 오디오가 있는 클립이 없습니다
- [ ] Silent audio → 음성을 찾지 못했습니다, not an empty document

## 8. Before a release

- [ ] `docs/RELEASE.md` end to end, on this Mac
- [ ] The dmg opens on a **different** Mac with no Gatekeeper warning
- [ ] The extension appears in Final Cut Pro on that Mac too
