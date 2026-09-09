import Foundation
import os

/// Talking to Final Cut Pro from inside the extension.
///
/// There is no API for putting content back into Final Cut Pro — the SDK's host interface is
/// read-only — so delivery is Apple's documented Open Document route: write the FCPXML, then ask
/// Final Cut Pro to open it. FCP shows its import sheet and the captions land on the project.
enum FinalCutPro {
    private static let log = Logger(subsystem: "com.jkh911208.FCPCaption", category: "delivery")

    /// Where a captioned document is written before Final Cut Pro is asked to open it.
    ///
    /// This is inside the extension's sandbox container, which Final Cut Pro can still read: it
    /// ships a `temporary-exception.files.absolute-path.read-write` entitlement for `/`. Writing
    /// somewhere the user picked would mean a save panel for every run.
    static func deliveryDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "FCPCaption/Delivered", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Writes the document and returns where it went. The name carries the clip so a folder of
    /// them is still readable a week later.
    static func write(_ document: Data, clipName: String) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let safeName = clipName.replacingOccurrences(of: "/", with: "-")
        let url = try deliveryDirectory().appending(path: "\(safeName) \(stamp).fcpxml")
        try document.write(to: url, options: .atomic)
        return url
    }

    /// Asks Final Cut Pro to open a file, which for FCPXML means importing it.
    ///
    /// AppleScript rather than a raw Apple Event because Apple documents it as the preferred form:
    /// it lets Final Cut Pro identify the calling app. Requires the scripting-target entitlement
    /// and, the first time, the user's permission in the automation prompt.
    static func open(_ url: URL) throws {
        let path = url.path(percentEncoded: false).replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Final Cut Pro"
            activate
            open POSIX file "\(path)"
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw DeliveryError.scriptFailed("스크립트를 만들지 못했습니다.")
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "알 수 없는 오류"
            log.error("open failed: \(message, privacy: .public)")
            throw DeliveryError.scriptFailed(message)
        }
    }

    enum DeliveryError: LocalizedError {
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case let .scriptFailed(detail):
                "Final Cut Pro에 파일을 보내지 못했습니다. 시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 자동화에서 FCPCaption을 허용했는지 확인해 주세요. (\(detail))"
            }
        }
    }
}
