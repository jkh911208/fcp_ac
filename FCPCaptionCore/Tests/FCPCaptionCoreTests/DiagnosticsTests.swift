import Foundation
import Testing
@testable import FCPCaptionCore

@Suite("SystemProfile")
struct SystemProfileTests {
    static let sample = SystemProfile(
        macModel: "Mac16,6",
        cpu: "Apple M4 Pro",
        performanceCores: 10,
        efficiencyCores: 4,
        memory: 24 * 1_073_741_824,
        macOSVersion: "15.6.1",
        macOSBuild: "24G90",
        appVersion: "0.1.1",
        host: "Final Cut Pro 12.3"
    )

    @Test("every field a report needs shows up in the table")
    func markdownCarriesEverything() {
        let markdown = Self.sample.markdown
        for expected in ["0.1.1", "Final Cut Pro 12.3", "15.6.1", "24G90", "Mac16,6", "Apple M4 Pro", "10P + 4E", "24 GB"] {
            #expect(markdown.contains(expected), "missing \(expected)")
        }
    }

    @Test("running outside Final Cut Pro says so rather than leaving a blank cell")
    func missingHostIsStated() {
        var profile = Self.sample
        profile.host = nil
        #expect(profile.markdown.contains("not running inside Final Cut Pro"))
    }

    @Test("a Mac with one core cluster does not claim 0P + 0E")
    func coresOmittedWhenUnknown() {
        var profile = Self.sample
        profile.performanceCores = 0
        profile.efficiencyCores = 0
        #expect(!profile.markdown.contains("Cores"))
    }

    @Test("memory reads as a size, not as bytes")
    func memoryIsHumanReadable() {
        #expect(SystemProfile.gigabytes(16 * 1_073_741_824) == "16 GB")
        #expect(SystemProfile.gigabytes(24 * 1_073_741_824) == "24 GB")
        #expect(SystemProfile.gigabytes(1_610_612_736) == "1.5 GB")
    }

    @Test("the report carries these rows and no others")
    func carriesNoPersonalData() {
        // Pinned by name, so adding a serial number, a user name, a hostname or a file path to the
        // report fails here rather than shipping quietly in everyone's bug reports.
        let labels = Self.sample.markdown
            .split(separator: "\n")
            .dropFirst(2)  // the header and its separator
            .compactMap { $0.split(separator: "|").first?.trimmingCharacters(in: .whitespaces) }
        #expect(labels == ["FCPCaption", "Host", "macOS", "Mac", "CPU", "Cores", "Memory"])
    }

    @Test("this Mac can actually be read — sysctl returns something for every key used")
    func readsThisMac() {
        let profile = SystemProfile.current(host: nil)
        // Not asserting particular values: this is a real machine and the point is that the
        // lookups resolve at all. "unknown" here would mean the report is useless in the field.
        #expect(profile.macModel != "unknown")
        #expect(profile.cpu != "unknown")
        #expect(profile.macOSBuild != "unknown")
        #expect(profile.memory > 0)
        // Not pinned to a major version: this Mac already runs macOS 26, and an assertion that
        // assumed 15 would have started failing on somebody else's machine, not here.
        #expect(Int(profile.macOSVersion.split(separator: ".").first ?? "") ?? 0 >= 15)
    }
}

@Suite("DiagnosticsBundle")
struct DiagnosticsBundleTests {
    private func staging() -> URL {
        let url = URL.temporaryDirectory.appending(path: "fcpcaption-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the zip is written and is not empty")
    func writesAZip() throws {
        let directory = staging()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "diagnostics.zip")

        try DiagnosticsBundle.write(
            .init(profile: SystemProfileTests.sample, note: "드래그가 먹지 않습니다"),
            to: destination,
            log: { "17:27:02 [drop] drag entered" }
        )

        #expect(FileManager.default.fileExists(atPath: destination.path))
        let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int ?? 0
        #expect(size > 0)
    }

    @Test("a file that was asked for and does not exist is skipped, not fatal")
    func missingAttachmentIsSurvivable() throws {
        let directory = staging()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "diagnostics.zip")

        try DiagnosticsBundle.write(
            .init(
                profile: SystemProfileTests.sample,
                attachments: [directory.appending(path: "host-trace-that-never-existed.txt")]
            ),
            to: destination,
            log: { "" }
        )
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("writing twice to the same path overwrites instead of failing")
    func overwritesAnEarlierReport() throws {
        let directory = staging()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "diagnostics.zip")

        try DiagnosticsBundle.write(.init(profile: SystemProfileTests.sample), to: destination, log: { "a" })
        try DiagnosticsBundle.write(.init(profile: SystemProfileTests.sample), to: destination, log: { "b" })
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("the note is included when written, and no empty heading appears when not")
    func noteIsOptional() {
        let withNote = DiagnosticsBundle.report(.init(profile: SystemProfileTests.sample, note: "드래그가 먹지 않습니다"))
        #expect(withNote.contains("What happened"))
        #expect(withNote.contains("드래그가 먹지 않습니다"))

        let blank = DiagnosticsBundle.report(.init(profile: SystemProfileTests.sample, note: "   \n "))
        #expect(!blank.contains("What happened"))
    }

    @Test("the issue URL carries the environment and points at this repository")
    func issueURLIsPrefilled() throws {
        let url = try #require(DiagnosticsBundle.issueURL(contents: .init(profile: SystemProfileTests.sample)))
        #expect(url.absoluteString.hasPrefix("https://github.com/jkh911208/fcp_ac/issues/new"))
        let body = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "body" })?.value
        )
        #expect(body.contains("Apple M4 Pro"))
        #expect(body.contains("Final Cut Pro 12.3"))
    }

    @Test("an unreadable log says so instead of returning an empty file that reads as 'all fine'")
    func emptyLogIsExplained() {
        let text = DiagnosticsBundle.recentLog(hours: 6)
        #expect(!text.isEmpty)
    }
}
