# FCPCaption

Final Cut Pro를 떠나지 않고 만드는 한국어 자동 자막.

[English README](README.md) · [웹사이트](https://jkh911208.github.io/fcp_ac/)

> **상태: 개발 중.** 마일스톤 M0(전사 스파이크)까지 완료했습니다. 동작하는 CLI가 있고 자막 분할
> 규칙은 테스트로 덮여 있지만, Workflow Extension 자체는 아직 만들지 않았습니다. Releases에서
> 받을 수 있는 빌드는 아직 없습니다. [PROGRESS.md](PROGRESS.md)를 참고하세요.

## 왜 만드나

Final Cut Pro 12.3의 내장 *Transcribe to Captions*는 **미국 영어 전용**입니다. 한국어 음성을 넣으면
영어 모델이 억지로 로마자화한 자막이 나옵니다. 지금의 대안은 왕복 작업뿐입니다 — 다른 앱에서 전사하고,
SRT/FCPXML로 내보내고, FCP에서 다시 임포트.

FCPCaption은 FCP 사이드바에 사는 Workflow Extension입니다. 클립을 패널로 끌어다 놓으면, 한국어 자막이
원본 클립에 연결된 상태로 타임라인 캡션 레인에 생깁니다.

## 동작 방식

1. FCP 타임라인에서 클립을 패널로 드래그합니다 (FCP가 FCPXML을 넘겨줍니다).
2. AVFoundation으로 원본 미디어에서 오디오를 추출합니다 — ffmpeg 없이, 재인코딩 왕복 없이.
3. 설정에서 고른 두 엔진 중 하나로 전사합니다.
   - **이 Mac에서** — [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML, 온디바이스).
     모델은 처음 한 번만 내려받고, 그 뒤로는 아무것도 기기를 떠나지 않습니다.
   - **OpenRouter** — 로컬 연산을 쓰고 싶지 않을 때, 본인의 API 키로.
4. 전사 결과를 한국어 자막 규칙에 맞게 캡션 단위로 나눕니다 (한 줄 18자, 최대 2줄, 1~6초,
   침묵과 문장 부호에서 끊고, 어절은 중간에서 자르지 않음).
5. 캡션을 iTT 캡션 레인으로 FCP에 되돌려 씁니다.

## 요구 사항

- **Apple silicon** Mac (M 시리즈). 인텔은 범위 밖입니다 — 로컬 모델이 Neural Engine에서 돌아갑니다.
- macOS 15 (Sequoia) 이상.
- Final Cut Pro 12.x.
- 클라우드 엔진을 쓸 때만: [OpenRouter](https://openrouter.ai) API 키. Keychain에 저장됩니다.

## 개인정보

텔레메트리, 애널리틱스, 계정 모두 없습니다. 로컬 모드에서는 전사 모델 다운로드 외에 네트워크 요청을
하지 않습니다. OpenRouter 모드에서는 본인 키로 OpenRouter에만 오디오가 전송됩니다. API 키는 macOS
Keychain에만 저장되고 로그에는 남지 않습니다.

## 설치

서명·공증된 `.dmg`를 [Releases 페이지](https://github.com/jkh911208/fcp_ac/releases)에 올릴
예정입니다. 아직 없습니다 — 위의 상태를 참고하세요.

## 소스에서 빌드

```bash
git clone git@github.com:jkh911208/fcp_ac.git
cd fcp_ac/FCPCaptionCore
swift build && swift test
```

전사 스파이크는 아무 오디오/비디오 파일로 바로 시험해 볼 수 있습니다.

```bash
swift run -c release fcpcaption-cli /path/to/clip.mov --model large-v3-turbo --language ko
```

첫 실행에서 모델(약 600MB)을 `~/Library/Application Support/FCPCaption/models`에 내려받고,
입력 파일과 같은 위치에 `.srt`를 씁니다.

## 로드맵

| 마일스톤 | 산출물 |
|---|---|
| **M0** ✅ | CLI 스파이크: 파일 → WhisperKit → `.srt`, 한국어 자막 규칙 테스트 |
| M1 | Extension 껍데기: FCP 사이드바 패널, 드롭된 FCPXML 파싱 |
| M2 | 임포트 스파이크: 이미 열린 프로젝트의 클립에 캡션을 붙일 수 있는가 |
| M3 | 로컬 E2E: 드래그 → 전사 → 타임라인에 자막 |
| M4 | OpenRouter 엔진, Keychain, 설정 화면 |
| M5 | 서명·공증 dmg, GitHub Actions 빌드 |

## 라이선스

MIT — [LICENSE](LICENSE) 참고.
