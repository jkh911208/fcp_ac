import SwiftUI

/// The container app.
///
/// macOS only ships an app extension inside an application, so this exists to carry
/// `FCPCaptionExtension` and to be the thing the user drags to /Applications. The work happens in
/// the extension, inside Final Cut Pro's sidebar — there is nothing to do here.
@main
struct FCPCaptionApp: App {
    var body: some Scene {
        Window("FCPCaption", id: "main") {
            VStack(spacing: 14) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                Text("FCPCaption").font(.title2).bold()
                Text("Final Cut Pro에서 **Window ▸ Extensions ▸ FCPCaption**을 열면\n사이드바에 패널이 나타납니다.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("이 창에서 할 일은 없습니다. 이 앱은 확장 프로그램을 담고 있을 뿐입니다.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(40)
            .frame(width: 420, height: 260)
        }
        .windowResizability(.contentSize)
    }
}
