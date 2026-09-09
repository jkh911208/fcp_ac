import Foundation

/// A colour as the two formats write it.
public struct CaptionColor: Sendable, Equatable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
        self.alpha = min(1, max(0, alpha))
    }

    public static let white = CaptionColor(red: 1, green: 1, blue: 1)
    public static let black = CaptionColor(red: 0, green: 0, blue: 0)
    public static let clear = CaptionColor(red: 0, green: 0, blue: 0, alpha: 0)

    /// FCPXML writes colours as space-separated components, e.g. `1 1 1 1`.
    public var fcpxmlValue: String {
        [red, green, blue, alpha].map { String(format: "%.4g", $0) }.joined(separator: " ")
    }

    /// TTML writes them as `#RRGGBBAA`.
    public var ittValue: String {
        let channels = [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
        return "#" + channels.map { String(format: "%02X", $0) }.joined()
    }
}

/// How the caption text looks.
///
/// **The two delivery routes carry different halves of this**, and Settings says which is which
/// rather than showing a control that quietly does nothing:
///
/// - FCPXML's `text-style` takes every attribute here — it is what Final Cut Pro itself writes,
///   down to `font=".Apple SD Gothic NeoI" fontSize="13"` in the reference export.
/// - An iTT caption file is TTML, which has colour, weight, style, decoration, size as a
///   percentage, alignment and an outline — but **no font name, kerning, line spacing, baseline
///   offset or shadow**.
public struct CaptionStyle: Sendable, Equatable, Codable {
    // Reaches both routes
    /// Points, as FCPXML measures them. Final Cut Pro's own Korean caption is 13.
    public var fontSize: Int
    public var fontColor: CaptionColor
    public var backgroundColor: CaptionColor
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var alignment: Alignment
    public var strokeColor: CaptionColor
    /// Outline thickness. 0 means none.
    public var strokeWidth: Double

    // FCPXML only
    /// A font family name, or nil for the one Final Cut Pro uses for Korean captions.
    public var fontName: String?
    public var fontFace: String?
    public var shadowColor: CaptionColor
    /// `"distance angle"`, the way FCPXML writes it. 0 distance means no shadow.
    public var shadowDistance: Double
    public var shadowAngle: Double
    public var shadowBlurRadius: Double
    public var kerning: Double
    public var lineSpacing: Double
    public var baselineOffset: Double

    public enum Alignment: String, Sendable, Equatable, Codable, CaseIterable {
        case left, center, right, justified

        public var korean: String {
            switch self {
            case .left: "왼쪽"
            case .center: "가운데"
            case .right: "오른쪽"
            case .justified: "양쪽"
            }
        }
    }

    public init(
        fontSize: Int = 13,
        fontColor: CaptionColor = .white,
        backgroundColor: CaptionColor = .black,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        alignment: Alignment = .center,
        strokeColor: CaptionColor = .black,
        strokeWidth: Double = 0,
        fontName: String? = nil,
        fontFace: String? = nil,
        shadowColor: CaptionColor = .black,
        shadowDistance: Double = 0,
        shadowAngle: Double = 315,
        shadowBlurRadius: Double = 0,
        kerning: Double = 0,
        lineSpacing: Double = 0,
        baselineOffset: Double = 0
    ) {
        self.fontSize = max(6, min(96, fontSize))
        self.fontColor = fontColor
        self.backgroundColor = backgroundColor
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.alignment = alignment
        self.strokeColor = strokeColor
        self.strokeWidth = max(0, strokeWidth)
        self.fontName = fontName
        self.fontFace = fontFace
        self.shadowColor = shadowColor
        self.shadowDistance = max(0, shadowDistance)
        self.shadowAngle = shadowAngle
        self.shadowBlurRadius = max(0, shadowBlurRadius)
        self.kerning = kerning
        self.lineSpacing = lineSpacing
        self.baselineOffset = baselineOffset
    }

    public static let `default` = CaptionStyle()

    /// The font Final Cut Pro uses for a Korean caption, unless overridden.
    public var fcpxmlFontName: String { fontName ?? ".Apple SD Gothic NeoI" }

    /// TTML has no point sizes; it scales from the player's default, and 13pt is Final Cut Pro's
    /// baseline for a caption.
    public var ittFontSizePercent: Int {
        max(25, Int((Double(fontSize) / 13.0 * 100).rounded()))
    }

    /// Titles are on a different type scale entirely: Final Cut Pro's Subtitle template writes
    /// `fontSize="100"` where a caption is `13`. Carrying a caption's size straight across would
    /// produce text too small to read, so it is scaled.
    public var titleFontSize: Int { max(10, Int((Double(fontSize) / 13.0 * 100).rounded())) }

    /// The same attributes as a caption, at the title type scale, with the defaults Final Cut
    /// Pro's own Subtitle title uses.
    public var titleAttributes: [(String, String)] {
        var attributes = fcpxmlAttributes
        if let index = attributes.firstIndex(where: { $0.0 == "fontSize" }) {
            attributes[index] = ("fontSize", String(titleFontSize))
        }
        if let index = attributes.firstIndex(where: { $0.0 == "font" }) {
            attributes[index] = ("font", fontName ?? "Helvetica Neue")
        }
        return attributes
    }

    /// The attributes an iTT caption file cannot carry, named so Settings can say so.
    public static let notInCaptionFiles = "글꼴 이름 · 자간 · 줄 간격 · 기준선 · 그림자"

    /// Every FCPXML `text-style` attribute, in the DTD's order.
    public var fcpxmlAttributes: [(String, String)] {
        var attributes: [(String, String)] = [
            ("font", fcpxmlFontName),
            ("fontSize", String(fontSize)),
            ("fontFace", fontFace ?? "Regular"),
            ("fontColor", fontColor.fcpxmlValue),
            ("backgroundColor", backgroundColor.fcpxmlValue),
        ]
        if bold { attributes.append(("bold", "1")) }
        if italic { attributes.append(("italic", "1")) }
        if strokeWidth > 0 {
            attributes.append(("strokeColor", strokeColor.fcpxmlValue))
            attributes.append(("strokeWidth", String(format: "%g", strokeWidth)))
        }
        if shadowDistance > 0 {
            attributes.append(("shadowColor", shadowColor.fcpxmlValue))
            attributes.append(("shadowOffset", "\(String(format: "%g", shadowDistance)) \(String(format: "%g", shadowAngle))"))
            attributes.append(("shadowBlurRadius", String(format: "%g", shadowBlurRadius)))
        }
        if kerning != 0 { attributes.append(("kerning", String(format: "%g", kerning))) }
        attributes.append(("alignment", alignment.rawValue))
        if lineSpacing != 0 { attributes.append(("lineSpacing", String(format: "%g", lineSpacing))) }
        if baselineOffset != 0 { attributes.append(("baselineOffset", String(format: "%g", baselineOffset))) }
        if underline { attributes.append(("underline", "1")) }
        return attributes
    }

    /// The TTML styling attributes an iTT file can carry.
    public var ittAttributes: [(String, String)] {
        var attributes: [(String, String)] = [
            ("tts:color", fontColor.ittValue),
            ("tts:backgroundColor", backgroundColor.ittValue),
            ("tts:fontFamily", "sansSerif"),
            ("tts:fontSize", "\(ittFontSizePercent)%"),
            ("tts:fontStyle", italic ? "italic" : "normal"),
            ("tts:fontWeight", bold ? "bold" : "normal"),
            ("tts:textAlign", alignment == .justified ? "center" : alignment.rawValue),
        ]
        if underline { attributes.append(("tts:textDecoration", "underline")) }
        if strokeWidth > 0 {
            attributes.append(("tts:textOutline", "\(strokeColor.ittValue) \(String(format: "%g", strokeWidth))px"))
        }
        return attributes
    }
}
