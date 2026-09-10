# FCPCaption

Final Cut Pro를 떠나지 않고 만드는 한국어 자동 자막.

[English README](README.md) · [웹사이트](https://jkh911208.github.io/fcp_ac/)

> **배포됐습니다** — [dmg 내려받기](https://github.com/jkh911208/fcp_ac/releases/latest).
> 서명·공증됐고, Final Cut Pro 12에서 처음부터 끝까지 실제로 확인했습니다.

## 왜 만드나

Final Cut Pro 12.3의 내장 *Transcribe to Captions*는 **미국 영어 전용**입니다. 한국어 음성을 넣으면
영어 모델이 억지로 로마자화한 자막이 나옵니다. 지금의 대안은 왕복 작업뿐입니다 — 다른 앱에서 전사하고,
SRT/FCPXML로 내보내고, FCP에서 다시 임포트.

FCPCaption은 Final Cut Pro 사이드바에 사는 Workflow Extension입니다. 프로젝트를 패널에 끌어다 놓으면
한국어 자막이 타임라인으로, 그 말이 나온 클립 위에 그대로 돌아옵니다. 업로드도 재인코딩도 없습니다.

## 동작 방식

1. **Final Cut Pro 브라우저에서 프로젝트를 패널로 드래그합니다.** (타임라인이 아니라 브라우저에서 —
   Final Cut Pro는 브라우저와 사이드바에서만 드래그를 시작합니다.) FCP가 프로젝트의 FCPXML을 넘겨줍니다.
2. **AVFoundation으로 오디오를 추출합니다** — ffmpeg 없이, 재인코딩 없이, 각 클립이 실제로 쓰는
   구간만. 컷 편집으로 잘려나간 부분은 전사하지 않습니다.
3. **이 Mac에서 전사합니다.** [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML,
   Neural Engine). 모델은 처음 한 번만 내려받고, 그 뒤로는 아무것도 기기를 떠나지 않습니다.
4. **전사 결과를 한국어 자막 규칙으로 나눕니다** — 한 줄 18자, 최대 2줄, 1~6초, 침묵과 문장 부호에서
   끊고 어절은 중간에서 자르지 않습니다. 이 숫자들은 전부 설정에서 바꿀 수 있습니다.
5. **자막을 Final Cut Pro로 되돌립니다.** 편한 쪽으로 고르면 됩니다.
   - **자막 파일로 저장** (`.itt`) 후 File ▸ Import ▸ Captions… — 이미 열어둔 프로젝트에 한국어로
     태그된 채 들어가고, 새로 생기는 것은 없습니다.
   - **Final Cut Pro로 바로 보내기** — 라이브러리를 고르고 Replace를 누르면, 편집하던 그 프로젝트가
     제자리에서 갱신됩니다. 캡션이든 타이틀이든 둘 다든.

## 요구 사항

- **Apple silicon** Mac (M 시리즈). 인텔은 범위 밖입니다 — 모델이 Neural Engine에서 돌아갑니다.
- macOS 15 (Sequoia) 이상.
- Final Cut Pro 12.x.
- 모델용 디스크 약 3GB, 최초 1회 다운로드. 각 모델을 처음 쓸 때 Neural Engine용 컴파일이 몇 분
  걸리는데, 이것도 한 번뿐입니다.
- 프로젝트를 Final Cut Pro로 바로 보내려면 macOS가 물어볼 때 FCPCaption의 제어를 허용해 주세요
  (시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 자동화). 자막 파일 저장은 권한이 필요 없습니다.

## 개인정보

텔레메트리도, 애널리틱스도, 계정도, 서버도 없습니다. **오디오도 전사 결과도 Mac을 떠나지
않습니다** — 전사는 전부 이 Mac에서 일어나고, 프로젝트에 관한 것은 아무것도 밖으로 나가지 않습니다.

이 앱이 하는 네트워크 요청은 두 종류뿐이고, 둘 다 분명히 적어둡니다:

- **모델 다운로드** — 모델당 한 번.
- **업데이트 확인** — 패널을 열 때 GitHub의 공개 릴리스 엔드포인트에 인증 없는 `GET` 한 번.
  계정도, 식별자도, 사용자에 관한 어떤 데이터도 보내지 않습니다. 설정에서 끌 수 있고, 무언가를
  설치하지도 않습니다 — 새 버전이 있다고 알려주고 페이지를 열어줄 뿐입니다.

## 캡션과 타이틀

Final Cut Pro는 이 둘을 다른 물건으로 다루고, 각자 잘하는 일이 다릅니다. 패널은 둘 중 하나든 둘 다든
씁니다 — 한 타임라인에 같이 올라갑니다.

| | 캡션 | 타이틀 |
|---|---|---|
| FCP에서 나중에 폰트 바꾸기 | 안 됩니다 | 모든 항목 |
| 자막 파일로 내보내기 | 됩니다 | 안 됩니다 |
| Captions 색인에 뜨고 역할로 껐다 켜기 | 됩니다 | 안 됩니다 |
| 유튜브에서 | `.srt`를 자막 트랙으로 업로드 | 화면에 구워짐 |

어느 쪽이든 글자 모양은 만들기 전에 직접 정합니다 — 크기, 색, 배경, 굵게, 기울임, 밑줄, 정렬,
외곽선, 폰트, 그림자, 자간, 줄 간격, 베이스라인. Final Cut Pro는 자기 인스펙터에 조절 항목이 없는
값도 앱이 써 준 대로 렌더링합니다.

## 설정

- **모델** — `large-v3` (3.0GB, 기본값) 또는 `large-v3-turbo` (1.5GB, 약 4배 빠르고 정확도는 조금 낮음).
- **어려운 구간 재시도** — 켜면 그냥 두면 놓칠 말을 살려내고, 대신 같은 파일을 두 번 돌려도 결과가
  똑같지는 않습니다. 실제로 재보고 패널에 설명해 뒀습니다.
- **언어** — 한국어, 영어, 자동 감지. 자막에 붙는 언어 태그도 이 값입니다.
- **자막 규칙** — 한 줄 글자 수, 줄 수, 최소·최대 길이, 자막을 끊는 침묵 길이.

## 커맨드라인

Final Cut Pro 없이 같은 파이프라인을 돌립니다. 품질을 빨리 확인할 때 좋습니다.

```bash
cd FCPCaptionCore && swift build -c release
.build/release/fcpcaption-cli clip.mov --language ko          # -> clip.srt
.build/release/fcpcaption-cli 내프로젝트.fcpxmld                # -> *.captioned.fcpxml, .itt
```

옵션: `--model large-v3|large-v3-turbo`, `--language ko|auto`, `--output 경로`,
`--compute neuralEngine|gpu|all`, `--workers N`, `--fallbacks N`.

## 설치

1. [Releases 페이지](https://github.com/jkh911208/fcp_ac/releases)에서 `.dmg`를 받아
   **FCPCaption**을 응용 프로그램 폴더로 끌어다 놓습니다.
2. 한 번 실행합니다. 그래야 macOS가 Extension을 등록합니다.
3. Final Cut Pro에서 **윈도우 ▸ 확장 프로그램 ▸ FCPCaption**.

서명·공증된 빌드라 Gatekeeper 경고 없이 열립니다.

## 소스에서 빌드

```bash
git clone git@github.com:jkh911208/fcp_ac.git
cd fcp_ac
Tools/generate_project.rb && Tools/install_local.sh
```

Xcode 프로젝트를 만들고, 앱과 Extension을 빌드하고, `/Applications`에 설치한 뒤 Final Cut Pro에
등록까지 합니다. 테스트는:

```bash
cd FCPCaptionCore && swift test
```

## 로드맵

| 마일스톤 | 산출물 |
|---|---|
| **M0** ✅ | 전사 스파이크: 파일 → WhisperKit → `.srt` |
| **M1** ✅ | FCPXML 리더/라이터, 오디오 추출, Extension 본체 |
| **M2** ✅ | 실제 Final Cut Pro에서 모든 전달 경로를 시험 — 결과는 [PROGRESS.md](PROGRESS.md) |
| **M3** ✅ | 프로젝트를 끌어다 놓으면 타임라인에 자막 |
| M4 | OpenRouter 엔진 — 보류. 로컬 모델로 충분합니다 |
| **M5** ✅ | 서명·공증 dmg |

## 라이선스

MIT — [LICENSE](LICENSE) 참고.
