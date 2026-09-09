import Cocoa
import FCPCaptionCore
import FCPCaptionUI
import SwiftUI
import os

/// The extension's principal class — the object Final Cut Pro instantiates and puts in its sidebar.
///
/// It owns almost nothing: the panel is `PanelView` from the package, the work is `CaptionPipeline`,
/// and this class only wires them to AppKit and to Final Cut Pro.
///
/// **Everything here runs its setup on the main thread on purpose.** The SDK release notes: v1.0.3
/// "may not be compatible with the Swift 6 Runtime due to initialization of the principal
/// ViewController class from a background thread", with the fix being to dispatch that
/// initialization synchronously to the main thread. That is what `onMain` does.
@objc(FCPCaptionExtensionViewController)
final class FCPCaptionExtensionViewController: NSViewController {
    private static let log = Logger(subsystem: "com.jkh911208.FCPCaption", category: "panel")

    private var model: PanelModel?

    override func loadView() {
        onMain {
            let model = Self.makeModel()
            self.model = model

            let dropView = CaptionDropView(frame: NSRect(x: 0, y: 0, width: 340, height: 420))
            dropView.onDrop = { [weak model] data in
                MainActor.assumeIsolated { model?.receive(data) }
            }

            let panel = NSHostingView(rootView: PanelView(model: model) { url in
                MainActor.assumeIsolated { Self.openInFinalCutPro(url, model: model) }
            })
            panel.translatesAutoresizingMaskIntoConstraints = false
            dropView.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
                panel.topAnchor.constraint(equalTo: dropView.topAnchor),
                panel.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),
            ])

            self.view = dropView
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let host = ProExtensionHostSingleton() as? FCPXHost {
            Self.log.notice("host: \(host.name, privacy: .public) \(host.versionString, privacy: .public)")
        } else {
            // Not fatal — the panel still works, we just don't know who is hosting it.
            Self.log.error("host singleton did not conform to FCPXHost")
        }
    }

    // MARK: - Wiring

    @MainActor
    private static func makeModel() -> PanelModel {
        PanelModel(
            engineLabel: "",
            makePipeline: { settings in
                CaptionPipeline(
                    engine: WhisperKitEngine(model: settings.model, options: settings.engine),
                    captionOptions: settings.captions,
                    language: settings.language
                )
            },
            deliver: { document, clip in try FinalCutPro.write(document, clipName: clip.name) },
            store: .shared
        )
    }

    @MainActor
    private static func openInFinalCutPro(_ url: URL, model: PanelModel) {
        do {
            try FinalCutPro.open(url)
        } catch {
            Self.log.error("delivery failed: \(error.localizedDescription, privacy: .public)")
            NSAlert(error: error).runModal()
        }
    }

    /// Runs `work` on the main thread, synchronously, wherever it is called from.
    private func onMain(_ work: @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
        }
    }
}
