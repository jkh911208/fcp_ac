import FCPCaptionCore
import SwiftUI

/// The panel's settings. Everything measured in this project that has a trade-off is a control
/// here, with the trade-off written next to it rather than left for the user to discover.
public struct SettingsView: View {
    @Binding var settings: FCPCaptionSettings
    var onDone: () -> Void

    public init(settings: Binding<FCPCaptionSettings>, onDone: @escaping () -> Void) {
        self._settings = settings
        self.onDone = onDone
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("설정")
                    .font(.title3).bold()
                    .frame(maxWidth: .infinity, alignment: .leading)
                model
                Divider()
                reliability
                Divider()
                language
                Divider()
                advanced
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button(action: onDone) { Text("완료").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(16)
            }
            // Opaque, not a material: the settings scroll under this bar, and translucency let
            // radio buttons show through the button.
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // MARK: - Sections

    private var model: some View {
        section("음성 인식 모델") {
            Picker("", selection: $settings.model) {
                ForEach(WhisperModel.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            note("\(settings.model.summary)  ·  다운로드 \(settings.model.downloadSizeDescription)")
        }
    }

    private var reliability: some View {
        section("어려운 구간 처리") {
            Toggle("매번 같은 결과 (재현성 우선)", isOn: Binding(
                get: { settings.engine.isReproducible },
                set: { settings.engine.temperatureFallbackCount = $0 ? 0 : 5 }
            ))
            note(settings.engine.summary)
        }
    }

    private var language: some View {
        section("자막 언어") {
            Picker("", selection: Binding(
                get: { settings.language ?? "auto" },
                set: { settings.language = $0 == "auto" ? nil : $0 }
            )) {
                Text("한국어").tag("ko")
                Text("영어").tag("en")
                Text("자동 감지").tag("auto")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            note("자막에 기록되는 언어이기도 합니다. Final Cut Pro가 이 값으로 캡션 역할을 정합니다.")
        }
    }

    /// Laid out flat rather than behind a disclosure triangle: you are already inside Settings,
    /// and a 300pt-wide sidebar makes a triangle a hard target for no benefit.
    private var advanced: some View {
        section("자막 분할 규칙") {
            stepper("한 줄 최대 글자", value: $settings.captions.maxCharactersPerLine, range: 8...40, unit: "자")
            stepper("최대 줄 수", value: $settings.captions.maxLines, range: 1...3, unit: "줄")
            slider("자막 최소 길이", value: $settings.captions.minDuration, range: 0.5...3, unit: "초")
            slider("자막 최대 길이", value: $settings.captions.maxDuration, range: 2...12, unit: "초")
            slider("이 정도 쉬면 자막을 끊음", value: $settings.captions.silenceGap, range: 0.2...2, unit: "초")
            Button("기본값으로") { settings.captions = .default }
                .controlSize(.small)
                .padding(.top, 2)
        }
    }

    // MARK: - Pieces

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)\(unit)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func slider(_ title: String, value: Binding<TimeInterval>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.1f%@", value.wrappedValue, unit))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: 0.1)
        }
    }
}
