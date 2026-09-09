# FCPCaption

Korean auto-captions for Final Cut Pro, without leaving Final Cut Pro.

[한국어 README](README.ko.md) · [Website](https://jkh911208.github.io/fcp_ac/)

> **Status: in development.** Milestone M0 (transcription spike) is done — there is a working
> CLI, and the caption-splitting rules are covered by tests. The Workflow Extension itself is not
> built yet, so there is nothing to install from Releases. See [PROGRESS.md](PROGRESS.md).

## Why

Final Cut Pro 12.3's built-in *Transcribe to Captions* is **US English only**. Feed it Korean
speech and you get an English model romanizing sounds it doesn't understand. The alternative today
is a round trip: transcribe in some other app, export SRT/FCPXML, import back into FCP.

FCPCaption is a Workflow Extension that lives in the FCP sidebar. Drag a clip onto the panel, and
the Korean captions land on the timeline's caption lane, attached to the clip they came from.

## How it works

1. You drag a clip from the FCP timeline onto the panel (FCP hands over FCPXML).
2. Audio is extracted from the original media with AVFoundation — no ffmpeg, no re-encode round trip.
3. It is transcribed by one of two engines, your choice in Settings:
   - **On this Mac** — [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML, on-device).
     The model downloads once; after that, nothing leaves the machine.
   - **OpenRouter** — your own API key, for when you'd rather not spend the local compute.
4. The transcript is split into caption units under Korean subtitle rules (18 characters per line,
   2 lines, 1–6 seconds, breaking on silence and punctuation, never mid-어절).
5. The captions are written back into FCP as an iTT caption lane.

## Requirements

- **Apple silicon** Mac (M-series). Intel is out of scope — the local model runs on the Neural Engine.
- macOS 15 (Sequoia) or later.
- Final Cut Pro 12.x.
- For the cloud engine only: an [OpenRouter](https://openrouter.ai) API key. Stored in the Keychain.

## Privacy

No telemetry, no analytics, no account. In local mode the app makes no network requests except
downloading the transcription model. In OpenRouter mode, audio goes to OpenRouter under your own
key and nowhere else. Your API key lives in the macOS Keychain and never appears in logs.

## Install

Signed and notarized `.dmg` builds will be published on the
[Releases page](https://github.com/jkh911208/fcp_ac/releases). None yet — see Status above.

## Build from source

```bash
git clone git@github.com:jkh911208/fcp_ac.git
cd fcp_ac/FCPCaptionCore
swift build && swift test
```

Try the transcription spike on any audio or video file:

```bash
swift run -c release fcpcaption-cli /path/to/clip.mov --model large-v3-turbo --language ko
```

The first run downloads the model (~600 MB) into `~/Library/Application Support/FCPCaption/models`.
It writes a `.srt` next to the input file.

## Roadmap

| Milestone | What it delivers |
|---|---|
| **M0** ✅ | CLI spike: file → WhisperKit → `.srt`, Korean caption rules under test |
| M1 | Workflow Extension shell: panel in the FCP sidebar, parses dropped FCPXML |
| M2 | Import spike: can captions attach to clips in an already-open project? |
| M3 | Local end-to-end: drag → transcribe → captions on the timeline |
| M4 | OpenRouter engine, Keychain, Settings |
| M5 | Signed + notarized dmg, GitHub Actions build |

## License

MIT — see [LICENSE](LICENSE).
