# FCPCaption

Korean auto-captions for Final Cut Pro, without leaving Final Cut Pro.

[한국어 README](README.ko.md) · [Website](https://jkh911208.github.io/fcp_ac/)

> **v0.1.0 is out** — [download the dmg](https://github.com/jkh911208/fcp_ac/releases/latest).
> Signed, notarized, and tested end to end in Final Cut Pro 12.

## Why

Final Cut Pro 12.3's built-in *Transcribe to Captions* is **US English only**. Feed it Korean
speech and you get an English model romanizing sounds it doesn't understand. The alternative today
is a round trip: transcribe in some other app, export SRT/FCPXML, import back into FCP.

FCPCaption is a Workflow Extension that lives in the Final Cut Pro sidebar. Drag your project onto
the panel and the Korean captions come back on the timeline, on the clips they were spoken over.
Nothing is uploaded and nothing is re-encoded.

## How it works

1. **Drag a project from the Final Cut Pro browser onto the panel.** (Not from the timeline — Final
   Cut Pro only starts drags from the browser and sidebar.) FCP hands over the project's FCPXML.
2. **Audio is extracted with AVFoundation** — no ffmpeg, no re-encode, and only the range each clip
   actually uses, so trimmed-away footage is never transcribed.
3. **It is transcribed on this Mac** by [WhisperKit](https://github.com/argmaxinc/WhisperKit)
   (CoreML, on the Neural Engine). The model downloads once; after that nothing leaves the machine.
4. **The transcript is split into caption units** under Korean subtitle rules: 18 characters a line,
   two lines, 1–6 seconds, breaking on silence and punctuation and never mid-어절. Every number is
   adjustable.
5. **The captions go back to Final Cut Pro**, either way you like:
   - **Save a caption file** (`.itt`) and use File ▸ Import ▸ Captions… — it lands on the project
     you already have open, tagged Korean, with nothing duplicated.
   - **Send it to Final Cut Pro** — choose the library, press Replace, and the project you were
     editing is updated in place, with captions, titles, or both.

## Requirements

- **Apple silicon** Mac (M-series). Intel is out of scope — the model runs on the Neural Engine.
- macOS 15 (Sequoia) or later.
- Final Cut Pro 12.x.
- About 3 GB of disk for the model, downloaded once. The first run of a model also compiles it for
  the Neural Engine, which takes several minutes and happens only once.
- To send a project back to Final Cut Pro, allow FCPCaption to control it when macOS asks
  (System Settings ▸ Privacy & Security ▸ Automation). Saving a caption file needs no permission.

## Privacy

No telemetry, no analytics, no account, no server. The app makes exactly one kind of network
request — downloading the transcription model, once — and none after that. Your audio and your
transcript never leave the Mac.

## Captions or titles

Final Cut Pro treats them as different objects, and each is right for a different job. The panel
writes either, or both — they sit on one timeline together.

| | Caption | Title |
|---|---|---|
| Changing the font in FCP afterwards | not possible | every control |
| Exporting as a subtitle file | yes | no |
| Appears in the Captions index, toggled by role | yes | no |
| On YouTube | upload the `.srt` as a subtitle track | burned into the picture |

Either way the type is yours to set before you generate: size, colour, background, bold, italic,
underline, alignment, outline, font, shadow, kerning, line spacing and baseline. Final Cut Pro
renders what the app writes even where its own inspector offers no control.

## Settings

- **Model** — `large-v3` (3.0 GB, the default) or `large-v3-turbo` (1.5 GB, about four times
  faster, slightly less accurate).
- **Difficult passages** — whether to retry them. Retrying recovers speech that would otherwise be
  lost, at the cost of a run that does not repeat exactly. Measured, and explained in the panel.
- **Language** — Korean, English, or detect. This is also what the captions are tagged with.
- **Caption rules** — characters a line, lines, minimum and maximum duration, the silence that ends
  a caption.

## The command line

The same pipeline without Final Cut Pro, useful for checking quality quickly:

```bash
cd FCPCaptionCore && swift build -c release
.build/release/fcpcaption-cli clip.mov --language ko          # -> clip.srt
.build/release/fcpcaption-cli MyProject.fcpxmld               # -> *.captioned.fcpxml and .itt
```

Options: `--model large-v3|large-v3-turbo`, `--language ko|auto`, `--output PATH`,
`--compute neuralEngine|gpu|all`, `--workers N`, `--fallbacks N`.

## Install

1. Download the `.dmg` from the [Releases page](https://github.com/jkh911208/fcp_ac/releases)
   and drag **FCPCaption** into Applications.
2. Launch it once, so macOS registers the extension.
3. In Final Cut Pro: **Window ▸ Extensions ▸ FCPCaption**.

The build is signed and notarized, so it opens without a Gatekeeper warning.

## Build from source

```bash
git clone git@github.com:jkh911208/fcp_ac.git
cd fcp_ac
Tools/generate_project.rb && Tools/install_local.sh
```

That generates the Xcode project, builds the app and the extension, installs it into
`/Applications` and registers it with Final Cut Pro. Tests:

```bash
cd FCPCaptionCore && swift test
```

## Roadmap

| Milestone | What it delivers |
|---|---|
| **M0** ✅ | Transcription spike: file → WhisperKit → `.srt` |
| **M1** ✅ | FCPXML reader/writer, audio extraction, the extension itself |
| **M2** ✅ | Every delivery route tried in real Final Cut Pro — findings in [PROGRESS.md](PROGRESS.md) |
| **M3** ✅ | Drag a project in, captions on the timeline |
| M4 | OpenRouter engine — deferred, the local model is good enough |
| **M5** ✅ | Signed and notarized dmg |

## License

MIT — see [LICENSE](LICENSE).
