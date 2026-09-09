# FCPCaption — Final Cut Pro 한국어 자동 자막 Workflow Extension

> 이 문서는 Claude Code에게 프로젝트 전체 맥락을 넘기기 위한 스펙입니다.
> 작업 시작 전 이 문서를 끝까지 읽고, 불명확한 부분은 구현 전에 질문하세요.
> 이름(FCPCaption / fcp-caption)은 가칭이며 나중에 바뀔 수 있습니다.

---

## 1. 한 줄 요약

Final Cut Pro 사이드바에 뜨는 Workflow Extension. 사용자가 FCP 타임라인의 클립을 패널로 드래그하면(또는 선택 후 버튼 클릭), 클립의 오디오를 한국어로 전사해서 **FCP 캡션 레인에 자막 클립으로 붙여주는** macOS 앱. 무료·오픈소스(MIT)로 배포.

## 2. 배경 / 왜 만드나

- FCP 12.3의 내장 Transcribe to Captions / Generate Captions는 **미국 영어 전용**. 한국어 음성을 넣으면 영어 모델이 억지로 로마자화한 쓰레기 자막이 나옴.
- 기존 대안은 외부 앱에서 전사 → SRT/FCPXML로 내보내기 → FCP에서 다시 임포트하는 왕복 작업. 불편함.
- 유료 플러그인(mCaptionsAI 등)은 있지만 무료는 없음.
- 목표: **FCP를 떠나지 않고, 클립 하나 드래그하면 한국어 자막이 타임라인에 생긴다.**

## 3. 대상 사용자와 배포

- 대상: Apple silicon Mac에서 FCP로 한국어 콘텐츠를 편집하는 개인 크리에이터.
- 배포: GitHub Releases에 서명·공증된 .dmg. 라이선스 MIT. 서버 비용 0 — 전사는 로컬 또는 사용자 본인의 API 키로.
- 텔레메트리 없음. 로컬 모드에서는 네트워크 접근 0 (모델 다운로드 제외).

## 4. 범위

### 4.1 v1에 포함 (MVP)

1. FCP Workflow Extension으로 FCP 사이드바에 표시.
2. 입력: FCP에서 클립을 패널로 드래그 앤 드롭 (FCPXML 수신). 선택 클립 기반 버튼 방식도 있으면 좋지만, 드래그가 우선.
3. 클립의 원본 미디어에서 AVFoundation으로 오디오 추출 (ffmpeg 사용 금지).
4. 전사 엔진 2종, 설정에서 선택:
   - **로컬**: WhisperKit (CoreML, 온디바이스). 모델은 첫 실행 시 다운로드.
   - **클라우드**: OpenRouter `/api/v1/audio/transcriptions` (사용자 API 키).
5. 전사 결과를 한국어 자막 규칙에 맞게 캡션 단위로 분할.
6. FCPXML `<caption>` 클립으로 만들어 FCP에 임포트 → 원본 클립 위 캡션 레인에 연결.
7. 진행률 표시, 취소, 오류 메시지.
8. 설정 화면: 엔진 선택, 모델 관리(다운로드/삭제/용량 표시), API 키(Keychain), 자막 언어(기본 ko, 자동감지 옵션), 자막 분할 파라미터.

### 4.2 v1에 포함하지 않음 (Non-goals)

- 스타일 입힌 애니메이션 타이틀 템플릿 (mCaptionsAI 스타일). 캡션 레인의 일반 캡션(iTT)만 생성.
- 번역.
- 화자 분리(diarization).
- 자막 편집기 UI. 편집은 FCP 캡션 인스펙터에서 하면 됨.
- Windows / iPad.
- Mac App Store 배포 (GitHub 배포만).

## 5. 사용자 플로우

```
FCP 타임라인에서 클립 드래그 → 사이드바 패널에 드롭
  → 패널: 클립 이름, 길이, 엔진 표시 → [자막 생성] 버튼
  → 진행률 (오디오 추출 → 전사 → 자막 생성 → FCP 임포트)
  → 완료: 타임라인 캡션 레인에 한국어 자막 클립이 원본 클립에 연결된 상태로 생김
```

실패 시: 이유를 사람이 읽을 수 있는 한국어로 표시 + 재시도 버튼.

## 6. 아키텍처

```
FCPCaption.app (SwiftUI, macOS host app)
├── FCPCaptionExtension.appex   (Workflow Extension target — 실제 UI는 여기)
└── FCPCaptionCore (Swift Package, 테스트 가능한 순수 로직)
    ├── FCPXML/
    │   ├── FCPXMLReader      드롭된 FCPXML → ClipRef(미디어 URL, 프로젝트/시퀀스 정보, 클립 offset/start/duration, 프레임레이트, 클립 ID)
    │   └── FCPXMLWriter      [Caption] → FCP가 임포트 가능한 FCPXML 문자열
    ├── Audio/
    │   └── AudioExtractor    AVAssetExportSession/AVAssetReader → 16kHz mono PCM(로컬) 또는 m4a(클라우드). 청크 분할 지원.
    ├── Transcription/
    │   ├── TranscriptionEngine (protocol)
    │   ├── WhisperKitEngine
    │   ├── OpenRouterEngine   (OpenAI 호환 포맷. baseURL 주입 가능하게 해서 OpenAI/Groq도 나중에 붙일 수 있게)
    │   └── Models: TranscriptWord(text, start, end), TranscriptSegment
    ├── Captioning/
    │   └── CaptionBuilder    [TranscriptWord] → [Caption] (한국어 분할 규칙, §8)
    └── Settings/
        ├── SettingsStore     UserDefaults (엔진, 모델, 언어, 분할 파라미터)
        └── KeychainStore     API 키
```

핵심 원칙:
- `FCPCaptionCore`는 UI/FCP 의존성 없이 단독으로 단위 테스트 가능해야 함.
- `TranscriptionEngine` 프로토콜 하나로 로컬/클라우드를 추상화. 시그니처 예시:
  ```swift
  protocol TranscriptionEngine {
      var id: String { get }
      func transcribe(audio: URL, language: String?, progress: @escaping (Double) -> Void) async throws -> [TranscriptWord]
      func cancel()
  }
  ```
- 외부 의존성은 SPM으로 **WhisperKit 하나만**. GPL 코드/바이너리 동봉 금지.

## 7. 기술 요구사항

- 언어/툴: Swift 5.10+ (Swift 6 strict concurrency 가능하면 적용), SwiftUI, Xcode 최신 안정 버전, SPM.
- 최소 OS: macOS 15 (Sequoia). **Apple silicon(M 시리즈) 전용** — 모든 타겟에 `ARCHS = arm64`, `EXCLUDED_ARCHS = x86_64`. Universal 바이너리 만들지 말 것. 인텔 Mac 지원은 범위 밖 (WhisperKit이 CoreML/Neural Engine 기반이라 인텔에선 성능이 안 나옴).
- FCP: 12.x. Workflow Extension은 Apple의 Workflow Extensions SDK / ProExtension 프레임워크 사용.
- 오디오: AVFoundation만. 긴 클립은 청크로 분할(기본 5분, 겹침 2초) 후 타임스탬프에 오프셋 합산.
- 로컬 모델: WhisperKit이 Hugging Face `argmaxinc/whisperkit-coreml`에서 다운로드. 저장 위치 `~/Library/Application Support/FCPCaption/models/`. 기본 모델 `large-v3-turbo`, 옵션으로 `small`. 다운로드 진행률·취소·삭제 지원.
- OpenRouter: 오디오를 base64로 JSON 바디에 실어 전송. `response_format: verbose_json`, `timestamp_granularities: ["word"]`, `language: "ko"`. 기본 모델 `openai/whisper-large-v3` (설정에서 변경 가능). 실제 파라미터명은 **구현 시 OpenRouter 공식 문서를 확인**해서 맞출 것.
- API 키: Keychain에만 저장. 로그·크래시 리포트·UI 텍스트 어디에도 노출 금지.
- 로그: `os.Logger`. 개인정보(전사 텍스트, 파일 경로) 기본 로그에 남기지 않음.
- 동시성: 전사는 백그라운드 Task, UI는 MainActor. 취소는 협조적 취소(Task cancellation) + 엔진별 cancel().

## 8. 한국어 자막 분할 규칙 (CaptionBuilder)

단어 타임스탬프 배열을 아래 규칙으로 캡션 단위로 묶는다. 값은 전부 설정에서 조정 가능하게.

- 한 줄 최대 **18자** (공백 포함, 한글 기준). 최대 **2줄**.
- 캡션 최소 길이 **1.0초**, 최대 **6.0초**.
- 분할 우선순위: (1) 단어 사이 침묵 ≥ 0.6초 → 무조건 끊음 (2) 문장 부호(. ? ! …) 뒤 (3) 쉼표 뒤 (4) 글자 수 초과 시 마지막 공백.
- 어절(공백 단위)을 중간에서 자르지 않음.
- 시작/끝 시각은 단어 타임스탬프 그대로. 앞 캡션과 겹치면 겹치지 않게 앞 캡션 끝을 당김.
- 단어 타임스탬프가 없는 엔진 결과(세그먼트만)도 처리 가능해야 함 — 그 경우 세그먼트를 글자 수 비율로 나눔.

이 모듈은 반드시 픽스처 기반 단위 테스트를 갖출 것.

## 9. FCPXML 요구사항

- **첫 작업**: 실제 FCP에서 (a) 한국어 캡션이 하나 있는 프로젝트를 FCPXML로 내보낸 것, (b) 클립 하나를 Workflow Extension으로 드래그했을 때 받는 FCPXML — 이 둘을 `Fixtures/`에 넣고 스키마를 거기서 배운다. 문서/기억에 의존해서 `<caption>` 구조를 추측하지 말 것.
- 캡션 role은 `iTT?captions.ko` 형식으로 시작하되, 실제 FCP 내보내기 값을 확인 후 맞출 것.
- 시간 표현은 FCPXML 방식(유리수 `s` 단위, 프로젝트 프레임레이트에 맞춰 프레임 정렬). 반올림 정책을 명시적으로 두고 테스트할 것.
- Reader/Writer는 FCPXML 버전 차이에 유연해야 함 (버전 문자열 하드코딩 금지, 받은 문서의 버전을 그대로 되돌려줌).

## 10. 가장 불확실한 지점 — 먼저 검증할 것 (Spike)

**"이미 열려 있는 프로젝트의 기존 클립에 캡션을 붙여 넣기"가 Workflow Extension의 FCPXML 임포트로 가능한지**가 이 프로젝트의 최대 리스크. 본격 구현 전에 이것부터 최소 코드로 검증한다.

폴백 사다리 (위에서부터 시도, 되는 첫 단계로 확정):
1. Extension의 FCPXML 임포트로 캡션이 원본 클립에 연결된 상태로 기존 프로젝트에 들어감. ← 이상적
2. 안 되면: 캡션이 포함된 프로젝트 사본을 새 프로젝트로 임포트 (사용자에게 안내).
3. 안 되면: `.itt`/`.srt` 파일을 생성하고 FCP의 File > Import > Captions를 사용자에게 안내 (자동으로 Finder에 열어주기). 이 경우도 "FCP를 떠나지 않는" 경험은 유지됨.

Spike 결과는 `docs/SPIKE_IMPORT.md`에 무엇을 시도했고 무엇이 됐는지 기록.

## 11. UI 요구사항

- 패널 크기: FCP 사이드바 기본 폭(약 300–400pt)에서 깨지지 않게.
- 메인 화면: 드롭 영역 / 현재 클립 정보 / 엔진 표시 / [자막 생성] / 진행률 바 + 단계 텍스트 / 취소.
- 설정 화면: 엔진 라디오(이 Mac에서 · OpenRouter), 모델 관리, API 키 입력(SecureField), 언어, 분할 파라미터(고급).
- 한국어 UI 기본, 영어 로컬라이즈 파일도 준비 (Localizable.xcstrings).
- 다크/라이트 모드 대응. 시스템 폰트, 시스템 컬러만 사용.

## 12. 테스트

- `FCPCaptionCore` 단위 테스트: FCPXMLReader/Writer(픽스처 왕복), CaptionBuilder(한국어 케이스 10개 이상), AudioExtractor 청크 오프셋, OpenRouterEngine(URLProtocol 모킹).
- 수동 테스트 체크리스트 `docs/MANUAL_TEST.md`: 실제 FCP에서 1분 / 15분 / 60분 한국어 클립으로 로컬·클라우드 각각 확인.
- 샘플 오디오 픽스처는 저작권 문제 없는 것(직접 녹음)만.

## 13. 마일스톤

| 단계 | 산출물 | 완료 기준 |
|---|---|---|
| M0 Spike | CLI 타겟: 파일 → WhisperKit 전사 → .srt | 한국어 1분 클립에서 읽을 만한 자막 나옴 |
| M1 Extension 껍데기 | FCP 사이드바에 패널 표시, 드롭된 FCPXML을 파싱해 클립 정보 표시 | FCP에서 드래그 → 패널에 클립명·길이 표시 |
| M2 임포트 Spike | §10 검증 | `docs/SPIKE_IMPORT.md` 작성, 폴백 단계 확정 |
| M3 로컬 E2E | 드래그 → 로컬 전사 → FCP에 캡션 | 캡션 레인에 한국어 자막 생김 |
| M4 클라우드 | OpenRouter 엔진 + Keychain + 설정 | 엔진 전환해도 동일 결과 |
| M5 릴리스 | 서명·공증 dmg, README, LICENSE, GitHub Actions 빌드 | 다른 Mac에서 다운로드→설치→동작 |

## 14. Claude Code 작업 규칙

- **Xcode GUI에서만 가능한 작업**(타겟 추가, entitlements, 서명 설정, Developer 계정 연결)은 대신 해주지 말고, 정확히 무엇을 클릭해야 하는지 단계별로 알려주고 끝날 때까지 기다릴 것.
- 빌드는 `xcodebuild`로 직접 돌리고, 컴파일 에러는 스스로 고칠 것. 테스트도 `xcodebuild test`로 실행.
- 각 마일스톤 끝에 git commit. 커밋 메시지는 영어, 한 줄 요약 + 본문.
- `PROGRESS.md`를 유지: 현재 마일스톤, 된 것, 안 된 것, 다음 할 일, 막힌 이유. 세션이 끊겨도 이 파일만 읽으면 이어갈 수 있게.
- 확실하지 않은 Apple API(특히 Workflow Extension, FCPXML 스키마)는 추측해서 구현하지 말고 Apple 공식 문서/샘플/실제 FCP 출력물로 확인. 확인 불가하면 질문.
- 서드파티 제품(mCaptionsAI 등)의 코드·에셋·이름을 참고하거나 복제하지 말 것.
- 설명은 한국어로, 코드·주석·커밋은 영어로.
- 과도한 추상화 금지. v1 범위 밖 기능(번역, 화자분리, 스타일 템플릿)을 위한 훅을 미리 만들지 말 것. 단, `TranscriptionEngine` 프로토콜과 OpenAI 호환 baseURL 주입은 예외.

## 15. 완료 정의 (v1)

1. 한국어 15분 클립을 FCP에서 패널로 드래그하면, 로컬 모드에서 추가 조작 없이 캡션 레인에 자막이 생긴다.
2. 자막이 §8 규칙을 지키고, 타이밍이 원본 음성과 ±0.3초 이내로 맞는다.
3. OpenRouter 모드로 전환해도 1·2가 동일하게 성립한다.
4. 중간 취소가 즉시 동작하고, 실패 시 한국어 오류 메시지가 뜬다.
5. 서명·공증된 dmg를 다른 Mac에서 받아 설치하면 Gatekeeper 경고 없이 실행된다.
6. `FCPCaptionCore` 테스트가 CI에서 통과한다.

## 16. 사용자가 직접 준비할 것 (Claude Code가 못 하는 것)

- Apple Developer Program 가입 ($99/년) — M5 서명·공증에 필요. M0~M4는 없어도 됨.
- Xcode 설치, FCP 12.x 설치.
- 테스트용 한국어 영상 클립 (1분 / 15분 / 60분).
- OpenRouter API 키 (M4부터).
- §9의 픽스처 두 개를 FCP에서 직접 내보내기 (M1 시작 시 Claude Code가 방법을 안내).
