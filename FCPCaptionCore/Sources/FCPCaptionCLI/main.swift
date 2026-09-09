import Foundation
import FCPCaptionCore

// M0 spike tool: audio file -> WhisperKit -> Korean .srt, with no FCP and no UI in the way.
// It exists to answer "are the captions any good?" before any of the app is built, and stays
// afterwards as the fastest way to re-check transcription quality and timing.
//
//   swift run fcpcaption-cli <audio-file> [--model large-v3-turbo|small]
//                            [--language ko|auto] [--output out.srt]

struct Arguments {
    var input: URL
    var model: WhisperModel = .largeV3Turbo
    var language: String? = "ko"
    var output: URL?

    static func parse(_ raw: [String]) throws -> Arguments {
        var positional: [String] = []
        var model = WhisperModel.largeV3Turbo
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
        사용법: fcpcaption-cli <audio-file> [옵션]

          -m, --model     large-v3-turbo (기본) | small
          -l, --language  ko (기본) | auto | 그 외 언어 코드
          -o, --output    저장할 .srt 경로 (기본: 입력 파일과 같은 위치)
        """
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

do {
    let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
    guard FileManager.default.fileExists(atPath: arguments.input.path(percentEncoded: false)) else {
        throw CLIError.fileNotFound(arguments.input)
    }
    let output = arguments.output ?? arguments.input.deletingPathExtension().appendingPathExtension("srt")

    log("모델: \(arguments.model.displayName)  언어: \(arguments.language ?? "자동 감지")")
    log("입력: \(arguments.input.lastPathComponent)")

    let engine = WhisperKitEngine(model: arguments.model)
    let started = Date()

    // Progress arrives from decoding threads; keep the terminal line to whole percents.
    nonisolated(unsafe) var lastReported = -1
    let words = try await engine.transcribe(audio: arguments.input, language: arguments.language) { fraction in
        let percent = Int(fraction * 100)
        if percent > lastReported {
            lastReported = percent
            log("진행률 \(percent)%")
        }
    }

    let captions = CaptionBuilder().build(from: words)
    try SRTWriter.string(from: captions).write(to: output, atomically: true, encoding: .utf8)

    log("""
    완료: 단어 \(words.count)개 → 자막 \(captions.count)개, \
    \(String(format: "%.1f", Date().timeIntervalSince(started)))초 소요
    """)
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
