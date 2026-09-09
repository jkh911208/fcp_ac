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

    public init(model: PanelModel, onOpenInFinalCut: @escaping (URL) -> Void) {
        self.model = model
        self.onOpenInFinalCut = onOpenInFinalCut
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
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
        case let .ready(clip):
            clipCard(clip)
            wideButton("자막 생성", prominent: true) { model.start() }
        case let .working(stage, fraction):
            working(stage: stage, fraction: fraction)
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
            Text("브라우저에서 프로젝트나 클립을\n여기로 끌어다 놓으세요")
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

    private func clipCard(_ clip: ClipRef) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(clip.name)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(Self.duration(clip.durationSeconds))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func working(stage: CaptionPipeline.Stage, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
            HStack {
                Text(stage.korean)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            wideButton("취소") { model.cancel() }
        }
    }

    private func finishedView(_ finished: PanelModel.Finished) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("자막 \(finished.captionCount)개를 만들었습니다", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("\(finished.clipName) · Final Cut Pro에서 열면 자막이 들어간 프로젝트를 가져옵니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if finished.skipped > 0 {
                Label("\(finished.skipped)개는 기존 자막과 시간이 겹쳐 건너뛰었습니다", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            wideButton("Final Cut Pro에서 열기", prominent: true) { onOpenInFinalCut(finished.output) }
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
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
            Text(model.engineLabel)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
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
