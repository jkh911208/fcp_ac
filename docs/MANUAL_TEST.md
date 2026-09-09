# Manual test checklist

What the automated tests cannot reach: Final Cut Pro itself. Run this before a release, and after
any change to the panel, the writer, or delivery.

Record the date and the result. A checklist with no dates is a checklist nobody ran.

## Setup

- Apple silicon Mac, macOS 15+, Final Cut Pro 12.x
- `/Applications/FCPCaption.app` installed (only one copy anywhere — the SDK release notes warn
  that several copies get discovered and which one wins is undefined)
- Korean test clips of about **1 minute**, **15 minutes** and **60 minutes**

## 1. The panel appears

- [ ] **Window ▸ Extensions ▸ FCPCaption** exists
- [ ] Clicking it opens the panel
- [ ] The panel is legible at the FCP sidebar's narrowest width
- [ ] It follows the system appearance in both light and dark

## 2. A dropped clip

- [ ] Dragging a timeline clip onto the panel shows that clip's name and duration
- [ ] The name matches the clip, not the media file, when they differ
- [ ] Dropping something that is not a clip gives a Korean message, not a hang
- [ ] `log show --last 5m --predicate 'subsystem == "com.jkh911208.FCPCaption"'` names the
      pasteboard types that arrived — **record them**, they are still undocumented

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
