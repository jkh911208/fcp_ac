import Foundation
import FCPCaptionCore

// The whole pipeline without the extension: Korean captions for a Final Cut Pro clip.
//
// Two modes, chosen by what you hand it:
//
//   fcpcaption-cli <clip.fcpxml>   -> the same document with captions on its clip, ready to
//                                     re-import into Final Cut Pro (File > Import > XML...)
//   fcpcaption-cli <audio/video>   -> a plain .srt, which is how transcription quality gets
//                                     checked without FCP in the way
//
// Options: [--model large-v3|large-v3-turbo] [--language ko|auto] [--output PATH]

struct Arguments {
    var input: URL
    var model: WhisperModel = .default
    var language: String? = "ko"
    var output: URL?

    /// A `.fcpxml` (or the `Info.fcpxml` inside a `.fcpxmld` bundle) takes the FCP path; anything
    /// else is treated as media and produces an .srt.
    var isFCPXML: Bool {
        ["fcpxml", "fcpxmld"].contains(input.pathExtension.lowercased())
    }

    /// Never overwrite the document Final Cut Pro exported — write a sibling instead.
    var defaultOutput: URL {
        isFCPXML
            ? input.deletingPathExtension().appendingPathExtension("captioned.fcpxml")
            : input.deletingPathExtension().appendingPathExtension("srt")
    }

    static func parse(_ raw: [String]) throws -> Arguments {
        var positional: [String] = []
        var model = WhisperModel.default
        var language: String? = "ko"
        var output: URL?

        var index = 0
        while index < raw.count {
            let argument = raw[index]
            func value() throws -> String {
                index += 1
                guard index < raw.count else { throw CLIError.missingValue(argument) }
                return raw[index]
            }
            switch argument {
            case "--model", "-m":
                let name = try value()
                guard let match = WhisperModel.allCases.first(where: {
                    $0.displayName == name || $0.identifier == name
                }) else { throw CLIError.unknownModel(name) }
                model = match
            case "--language", "-l":
                let name = try value()
                language = (name == "auto") ? nil : name
            case "--output", "-o":
                output = URL(filePath: try value())
            case "--help", "-h":
                throw CLIError.help
            default:
                guard !argument.hasPrefix("-") else { throw CLIError.unknownOption(argument) }
                positional.append(argument)
            }
            index += 1
        }

        guard let first = positional.first else { throw CLIError.help }
        return Arguments(input: URL(filePath: first), model: model, language: language, output: output)
    }
}

enum CLIError: LocalizedError {
    case help
    case missingValue(String)
    case unknownOption(String)
    case unknownModel(String)
    case fileNotFound(URL)

    var errorDescription: String? {
        switch self {
        case .help:
            usage
        case let .missingValue(option):
            "\(option) 뒤에 값이 필요합니다.\n\n\(usage)"
        case let .unknownOption(option):
            "알 수 없는 옵션입니다: \(option)\n\n\(usage)"
        case let .unknownModel(name):
            "알 수 없는 모델입니다: \(name) (사용 가능: \(WhisperModel.allCases.map(\.displayName).joined(separator: ", ")))"
        case let .fileNotFound(url):
            "파일을 찾을 수 없습니다: \(url.path(percentEncoded: false))"
        }
    }

    var usage: String {
        """
        사용법: fcpcaption-cli <파일> [옵션]

          <파일>이 .fcpxml이면  → 자막을 넣은 .fcpxml (FCP에서 File ▸ Import ▸ XML…)
          <파일>이 영상/오디오면 → .srt

          -m, --model     large-v3 (기본, 3.0GB) | large-v3-turbo (1.5GB, 더 빠름)
          -l, --language  ko (기본) | auto | 그 외 언어 코드
          -o, --output    저장 경로 (기본: 입력 파일과 같은 위치)
        """
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Prints each whole percent once, from whichever thread got there first.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1

    func report(_ label: String, _ fraction: Double) {
        let percent = Int(fraction * 100)
        let shouldPrint = lock.withLock {
            guard percent > lastPercent else { return false }
            lastPercent = percent
            return true
        }
        if shouldPrint { log("[\(percent)%] \(label)") }
    }
}

do {
    let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
    guard FileManager.default.fileExists(atPath: arguments.input.path(percentEncoded: false)) else {
        throw CLIError.fileNotFound(arguments.input)
    }
    let output = arguments.output ?? arguments.defaultOutput

    log("모델: \(arguments.model.displayName)  언어: \(arguments.language ?? "자동 감지")")
    log("입력: \(arguments.input.lastPathComponent)")

    let engine = WhisperKitEngine(model: arguments.model)
    let started = Date()

    // Progress arrives from decoding threads, so the "last percent printed" counter is shared
    // state and needs a lock, not just a var.
    let reporter = ProgressReporter()
    let report: @Sendable (String, Double) -> Void = { label, fraction in reporter.report(label, fraction) }

    if arguments.isFCPXML {
        let pipeline = CaptionPipeline(engine: engine, language: arguments.language)
        let source = arguments.input.pathExtension.lowercased() == "fcpxmld"
            ? arguments.input.appending(path: "Info.fcpxml")
            : arguments.input
        let result = try await pipeline.run(document: try Data(contentsOf: source)) { stage, fraction in
            report(stage.korean, fraction)
        }
        try result.document.write(to: output)

        // The caption-file route is the one that reaches the project already open in Final Cut
        // Pro, with no dialog — so write it too, as .itt rather than .srt because only iTT can say
        // the captions are Korean.
        if let frameDuration = try FCPXMLReader().read(data: try Data(contentsOf: source)).frameDuration {
            let captionFile = output.deletingPathExtension().deletingPathExtension()
                .appendingPathExtension("itt")
            let itt = ITTWriter(language: arguments.language ?? "ko").string(
                from: result.captions.map { caption in
                    // Caption times are relative to the clip; the caption file is read against the
                    // timeline, so the clip's position on it has to be added back.
                    Caption(lines: caption.lines,
                            start: caption.start + result.clip.offset.seconds,
                            end: caption.end + result.clip.offset.seconds)
                },
                frameDuration: frameDuration
            )
            try itt.write(to: captionFile, atomically: true, encoding: .utf8)
            log("자막 파일: \(captionFile.lastPathComponent) (File ▸ Import ▸ Captions… 로 열면 지금 프로젝트에 바로 들어갑니다)")
        }

        log("클립: \(result.clip.name) (\(String(format: "%.1f", result.clip.durationSeconds))초)")
        log("""
        완료: 단어 \(result.words)개 → 자막 \(result.captions.count)개, \
        \(String(format: "%.1f", Date().timeIntervalSince(started)))초 소요
        """)
        log("Final Cut Pro에서 File ▸ Import ▸ XML… 로 이 파일을 불러오세요.")
    } else {
        let words = try await engine.transcribe(audio: arguments.input, language: arguments.language) { fraction in
            report("음성을 전사하는 중", fraction)
        }
        let captions = CaptionBuilder().build(from: words)
        try SRTWriter.string(from: captions).write(to: output, atomically: true, encoding: .utf8)
        log("""
        완료: 단어 \(words.count)개 → 자막 \(captions.count)개, \
        \(String(format: "%.1f", Date().timeIntervalSince(started)))초 소요
        """)
    }
    print(output.path(percentEncoded: false))
} catch let error as CLIError {
    log(error.localizedDescription)
    exit(error.isHelp ? 0 : 2)
} catch is CancellationError {
    log("작업을 취소했습니다.")
    exit(130)
} catch {
    log(error.localizedDescription)
    exit(1)
}

extension CLIError {
    var isHelp: Bool { if case .help = self { true } else { false } }
}
