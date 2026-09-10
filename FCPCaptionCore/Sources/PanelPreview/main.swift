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
func render(_ view: some View, to url: URL, appearance: NSAppearance.Name, height: CGFloat = 380) {
    let hosting = NSHostingView(rootView: view.frame(width: 340, height: height))
    hosting.appearance = NSAppearance(named: appearance)
    hosting.frame = CGRect(x: 0, y: 0, width: 340, height: height)

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
            makePipeline: { _ in fatalError("preview only") },
            deliver: { _, _ in URL(filePath: "/tmp/preview.fcpxml") },
            currentVersion: "0.1.2",
            lookUpUpdate: { _ in
                .init(version: "0.1.3",
                      url: URL(string: "https://github.com/jkh911208/fcp_ac/releases/latest")!)
            }
        )
        model.setStateForPreview(state)
        // Awaited synchronously so the render has the answer; the panel does this in the
        // background, where nothing is painted until it arrives.
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in await model.checkForUpdate(); semaphore.signal() }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return model
    }

    let states: [(String, PanelModel.State)] = [
        ("1-waiting", .waiting),
        ("2-ready", .ready(clips: [clip], hasTimeline: true)),
        ("3-working", .working(.init(stage: .transcribing, fraction: 0.42))),
        ("3b-downloading", .working(.init(stage: .downloadingModel, fraction: 0.38,
                                          detail: "1.1 GB / 3.0 GB · 42 MB/s · 이 모델을 처음 쓸 때 한 번만 받습니다"))),
        ("3c-loading", .working(.init(stage: .loadingModel, fraction: 0,
                                      detail: "이 모델을 처음 쓸 때만 몇 분 걸립니다. 다음부터는 바로 시작합니다."))),
        ("4-finished", .finished(.init(captionCount: 37, clipName: clip.name,
                                       output: URL(filePath: "/tmp/out.fcpxml"),
                                       captionFile: "<tt/>", captionFileBaseName: "인터뷰", keepsProject: true,
                                       omitted: [
                                           .init(clipName: "03", reason: "속도를 조절한 클립 (0.25배속)이라 건너뜁니다"),
                                           .init(clipName: "IMG_6081", reason: "음소거된 클립이라 건너뜁니다"),
                                       ]))),
        ("5-failed", .failed(message: "음성 인식 모델(large-v3-turbo)을 준비하지 못했습니다. 네트워크 연결과 디스크 여유 공간을 확인해 주세요.",
                             canRetry: true)),
    ]

    // Tall on purpose: the settings sit under every state now, so a 380pt crop would hide the
    // part being reviewed.
    for (name, state) in states {
        render(
            PanelView(model: model(state), onOpenInFinalCut: { _ in }, onSaveCaptionFile: { _, _ in },
                      onReportProblem: { _ in }, onOpenURL: { _ in }),
            to: directory.appending(path: "panel-\(name)-\(appearance == .darkAqua ? "dark" : "light").png"),
            appearance: appearance,
            height: 2400
        )
    }
}

run()
