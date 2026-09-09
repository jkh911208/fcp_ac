import AppKit
import FCPCaptionCore
import SwiftUI

/// The caption appearance controls, with a live preview.
///
/// Every FCPXML `text-style` attribute is here. The ones an iTT caption file cannot carry are
/// grouped together and labelled, because the delivery route most people will use is the caption
/// file — and a control that silently does nothing is worse than one that says so.
struct CaptionStyleView: View {
    @Binding var style: CaptionStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            preview

            Group {
                sizeAndFace
                colors
                outline
            }

            Divider()
            Text("자막 파일(.itt)에는 아래 항목이 반영되지 않습니다 — \(CaptionStyle.notInCaptionFiles)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                fontFamily
                shadow
                spacing
            }

            Button("기본값으로") { style = .default }
                .controlSize(.small)
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Text("한국어 자막 미리보기")
                .font(.system(size: max(9, CGFloat(style.fontSize)), weight: style.bold ? .bold : .regular))
                .italic(style.italic)
                .underline(style.underline)
                .foregroundStyle(color(style.fontColor))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color(style.backgroundColor))
                .shadow(color: color(style.shadowColor).opacity(style.shadowDistance > 0 ? 1 : 0),
                        radius: style.shadowBlurRadius, x: style.shadowDistance, y: style.shadowDistance)
                .frame(maxWidth: .infinity, alignment: alignment)
                .padding(8)
        }
        .frame(height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var alignment: Alignment {
        switch style.alignment {
        case .left: .leading
        case .right: .trailing
        default: .center
        }
    }

    // MARK: - Sections

    private var sizeAndFace: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(value: $style.fontSize, in: 6...96) {
                labelled("글자 크기", "\(style.fontSize)pt")
            }
            HStack(spacing: 12) {
                Toggle("굵게", isOn: $style.bold)
                Toggle("기울임", isOn: $style.italic)
                Toggle("밑줄", isOn: $style.underline)
            }
            .toggleStyle(.checkbox)
            Picker("정렬", selection: $style.alignment) {
                ForEach(CaptionStyle.Alignment.allCases, id: \.self) { Text($0.korean).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 8) {
            colorRow("글자색", $style.fontColor)
            colorRow("배경색", $style.backgroundColor)
        }
    }

    private var outline: some View {
        VStack(alignment: .leading, spacing: 8) {
            slider("외곽선 두께", value: $style.strokeWidth, range: 0...10, unit: "")
            if style.strokeWidth > 0 { colorRow("외곽선 색", $style.strokeColor) }
        }
    }

    private var fontFamily: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("글꼴", selection: Binding(
                get: { style.fontName ?? "" },
                set: { style.fontName = $0.isEmpty ? nil : $0 }
            )) {
                Text("Final Cut Pro 기본").tag("")
                Divider()
                ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    private var shadow: some View {
        VStack(alignment: .leading, spacing: 8) {
            slider("그림자 거리", value: $style.shadowDistance, range: 0...20, unit: "")
            if style.shadowDistance > 0 {
                slider("그림자 각도", value: $style.shadowAngle, range: 0...360, unit: "°")
                slider("그림자 흐림", value: $style.shadowBlurRadius, range: 0...20, unit: "")
                colorRow("그림자 색", $style.shadowColor)
            }
        }
    }

    private var spacing: some View {
        VStack(alignment: .leading, spacing: 8) {
            slider("자간", value: $style.kerning, range: -5...20, unit: "")
            slider("줄 간격", value: $style.lineSpacing, range: -20...40, unit: "")
            slider("기준선", value: $style.baselineOffset, range: -20...20, unit: "")
        }
    }

    // MARK: - Pieces

    /// Loaded once: a Mac can have several hundred families, and rebuilding the list on every
    /// keystroke in the panel would be felt.
    private static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    private func labelled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func colorRow(_ title: String, _ binding: Binding<CaptionColor>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { color(binding.wrappedValue) },
            set: { binding.wrappedValue = captionColor($0) }
        ), supportsOpacity: true)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            labelled(title, String(format: "%.0f%@", value.wrappedValue, unit))
            Slider(value: value, in: range, step: 1)
        }
    }

    private func color(_ caption: CaptionColor) -> Color {
        Color(.sRGB, red: caption.red, green: caption.green, blue: caption.blue, opacity: caption.alpha)
    }

    private func captionColor(_ color: Color) -> CaptionColor {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return CaptionColor(red: converted.redComponent, green: converted.greenComponent,
                            blue: converted.blueComponent, alpha: converted.alphaComponent)
    }
}
