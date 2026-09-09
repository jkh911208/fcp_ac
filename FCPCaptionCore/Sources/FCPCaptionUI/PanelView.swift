import FCPCaptionCore
import SwiftUI

/// The whole panel. Sized for Final Cut Pro's sidebar, which is about 300–400pt wide, and built
/// from system fonts and system colors only so it follows the host's appearance in both themes.
///
/// Every state is a case of `PanelModel.State` — the view never infers "still loading" from an
/// empty value, which is what keeps a real-looking placeholder from flashing before the data.
public struct PanelView: View {
    @Bindable var model: PanelModel
    var onOpenInFinalCut: (URL) -> Void
    var onSaveCaptionFile: ((String, String) -> Void)?
    /// Collects a diagnostics zip and opens a prefilled issue. The string is whatever context the
    /// panel already has — a failure message, or empty when the user starts the report themselves.
    var onReportProblem: ((String) -> Void)?

    public init(
        model: PanelModel,
        onOpenInFinalCut: @escaping (URL) -> Void,
        onSaveCaptionFile: ((String, String) -> Void)? = nil,
        onReportProblem: ((String) -> Void)? = nil
    ) {
        self.model = model
        self.onOpenInFinalCut = onOpenInFinalCut
        self.onSaveCaptionFile = onSaveCaptionFile
        self.onReportProblem = onReportProblem
    }

    public var body: some View {
        // One scrolling column, settings included. They used to live behind a gear button, which
        // in a sidebar this narrow meant a small target hiding most of what the panel can do —
        // and the panel had a screenful of empty space under the button anyway.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
                Divider()
                    .padding(.top, 2)
                // Visible but not editable during a run: changing the model under a running
                // transcription would describe a result that is not the one being produced.
                SettingsView(settings: $model.settings)
                    .disabled(isWorking)
                    .opacity(isWorking ? 0.4 : 1)
                if onReportProblem != nil {
                    Divider()
                    reportRow
                }
            }
            .padding(16)
        }
        .frame(minWidth: 280, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .waiting:
            dropTarget
        case .reading:
            busy("클립을 읽는 중…")
        case let .ready(clips, hasTimeline):
            clipCard(clips)
            if !hasTimeline {
                // A clip dragged from the browser carries no sequence, so its captions land on the
                // library clip — not on a timeline it has already been edited into. Saying so here
                // is cheaper than the user discovering it after a five-minute transcription.
                Label("클립만 받았습니다. 자막은 라이브러리 클립에 붙고, 이미 편집된 타임라인에는 나타나지 않습니다. 타임라인에 넣으려면 브라우저에서 **프로젝트**를 끌어다 놓으세요.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            wideButton("자막 생성", prominent: true) { model.start() }
        case let .working(report):
            working(report)
        case let .finished(finished):
            finishedView(finished)
        case let .failed(message, canRetry):
            failure(message: message, canRetry: canRetry)
        }
    }

    // MARK: - States

    private var dropTarget: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("브라우저에서 **프로젝트**를\n여기로 끌어다 놓으세요")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            // Final Cut Pro only starts drags from the sidebar and the browser — never from the
            // timeline. Saying so costs a line and saves the "why doesn't this work" minute.
            Text("타임라인에서는 드래그할 수 없습니다")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.tertiary)
        )
    }

    private func busy(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clipCard(_ clips: [ClipRef]) -> some View {
        let total = clips.reduce(0) { $0 + $1.durationSeconds }
        return VStack(alignment: .leading, spacing: 4) {
            Text(clips.count == 1 ? (clips.first?.name ?? "") : "클립 \(clips.count)개")
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(Self.duration(total))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if clips.count > 1 {
                // Naming them beats a bare count: it is how you notice a clip you did not mean
                // to caption before spending twenty minutes on it.
                Text(clips.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func working(_ report: CaptionPipeline.Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // A load reports nothing, so it gets a spinner. A bar frozen at a number for five
            // minutes is indistinguishable from a hang.
            if report.isIndeterminate {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: report.fraction).progressViewStyle(.linear)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(report.stage.korean)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if !report.isIndeterminate {
                    Text("\(Int(report.fraction * 100))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let detail = report.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            wideButton("취소") { model.cancel() }
        }
    }

    private func finishedView(_ finished: PanelModel.Finished) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("자막 \(finished.captionCount)개를 만들었습니다", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(finished.clipCount > 1 ? "클립 \(finished.clipCount)개" : finished.clipName)
                .font(.callout)
                .foregroundStyle(.secondary)
            if finished.skipped > 0 {
                Label("\(finished.skipped)개는 기존 자막과 시간이 겹쳐 건너뛰었습니다", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Two routes, and the difference matters: a caption file lands on the timeline you
            // are editing, while importing FCPXML brings a *copy* of the event and project into
            // the library. Saying which is which here saves discovering it afterwards.
            if let captionFile = finished.captionFile, let onSaveCaptionFile {
                VStack(alignment: .leading, spacing: 4) {
                    wideButton("자막 파일 저장", prominent: true) {
                        onSaveCaptionFile(captionFile, finished.captionFileBaseName)
                    }
                    Text("저장한 뒤 Final Cut Pro에서 **File ▸ Import ▸ Captions…** 로 열면\n지금 편집 중인 프로젝트에 그대로 들어갑니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                wideButton("Final Cut Pro로 보내기") { onOpenInFinalCut(finished.output) }
                Text(finished.keepsProject
                     ? "지금 프로젝트를 갱신합니다. 임포트 창에서 **Replace**를 누르세요."
                     : "프로젝트 사본이 라이브러리에 새로 생깁니다. 지금 프로젝트를 그대로 쓰려면 시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 자동화에서 FCPCaption이 Final Cut Pro를 제어하도록 허용해 주세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            wideButton("다른 클립 자막 만들기") { model.reset() }
        }
    }

    private func failure(message: String, canRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("자막을 만들지 못했습니다", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if canRetry {
                wideButton("다시 시도", prominent: true) { model.retry() }
            }
            wideButton("처음으로") { model.reset() }
            // Offered here with the error already in hand, so a report costs one click at the
            // moment the user has something to report.
            if let onReportProblem {
                wideButton("이 오류 신고하기") { onReportProblem(message) }
            }
        }
    }

    private var reportRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                onReportProblem?("")
            } label: {
                Label("문제 신고", systemImage: "ladybug")
            }
            .controlSize(.small)
            Text("이 Mac의 사양과 Final Cut Pro 버전, 최근 로그를 zip으로 모읍니다.\n올리기 전에 내용을 직접 확인하실 수 있고, 자동으로 전송되는 것은 없습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isWorking: Bool {
        if case .working = model.state { true } else { false }
    }

    /// A button that fills the panel's width. The `maxWidth` has to sit on the *label*: putting it
    /// on the Button only widens the hit area, leaving a small button centred in a wide gap.
    @ViewBuilder
    private func wideButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        let label = Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .controlSize(.large)
        if prominent {
            label.buttonStyle(.borderedProminent)
        } else {
            label.buttonStyle(.bordered)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (minutes, remainder) = total.quotientAndRemainder(dividingBy: 60)
        return minutes > 0 ? "\(minutes)분 \(remainder)초" : "\(remainder)초"
    }
}
