import AppKit
import FCPCaptionCore
import FCPCaptionUI
import SwiftUI

// Renders every panel state to PNG, at the width Final Cut Pro's sidebar actually gives us.
//
// This exists because a design change here has to be looked at before it ships (see CLAUDE.md),
// and "looked at" means a rendered image, not a description. Run:
//
//   swift run PanelPreview <output-directory> [light|dark]

@MainActor
func render(_ view: some View, to url: URL, appearance: NSAppearance.Name) {
    let hosting = NSHostingView(rootView: view.frame(width: 340, height: 380))
    hosting.appearance = NSAppearance(named: appearance)
    hosting.frame = CGRect(x: 0, y: 0, width: 340, height: 380)

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
    print(url.lastPathComponent)
}

@MainActor
func run() {
    let arguments = CommandLine.arguments
    let directory = URL(filePath: arguments.count > 1 ? arguments[1] : NSTemporaryDirectory())
    let appearance: NSAppearance.Name = (arguments.count > 2 && arguments[2] == "dark")
        ? .darkAqua : .aqua
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let clip = ClipRef(
        element: "asset-clip",
        assetID: "r2",
        name: "인터뷰_최종본_02",
        offset: .zero,
        start: .zero,
        duration: FCPTime(905, 1),
        mediaURL: URL(filePath: "/Movies/interview.mov")
    )

    func model(_ state: PanelModel.State) -> PanelModel {
        let model = PanelModel(
            engineLabel: "이 Mac에서 · large-v3-turbo",
            makePipeline: { fatalError("preview only") },
            deliver: { _, _ in URL(filePath: "/tmp/preview.fcpxml") }
        )
        model.setStateForPreview(state)
        return model
    }

    let states: [(String, PanelModel.State)] = [
        ("1-waiting", .waiting),
        ("2-ready", .ready(clip)),
        ("3-working", .working(stage: .transcribing, fraction: 0.42)),
        ("4-finished", .finished(.init(captionCount: 37, clipName: clip.name,
                                       output: URL(filePath: "/tmp/out.fcpxml")))),
        ("5-failed", .failed(message: "음성 인식 모델(large-v3-turbo)을 준비하지 못했습니다. 네트워크 연결과 디스크 여유 공간을 확인해 주세요.",
                             canRetry: true)),
    ]

    for (name, state) in states {
        render(
            PanelView(model: model(state), onOpenInFinalCut: { _ in }),
            to: directory.appending(path: "panel-\(name)-\(appearance == .darkAqua ? "dark" : "light").png"),
            appearance: appearance
        )
    }
}

run()
