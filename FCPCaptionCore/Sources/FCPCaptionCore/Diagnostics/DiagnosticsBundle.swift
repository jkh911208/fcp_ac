import Foundation
import OSLog

/// Collects what a bug report needs into a single zip the user can attach to a GitHub issue.
///
/// **Nothing is uploaded.** This project promises no server and no telemetry, and an API token
/// shipped inside the app is a token anyone can extract from it. So the flow is: build the file,
/// let the user save it, open a prefilled issue, and let them look at both before posting. The one
/// who decides what leaves the machine is the person whose machine it is.
public enum DiagnosticsBundle {
    /// Where the panel writes its own log, and the only subsystem collected.
    public static let subsystem = "com.jkh911208.FCPCaption"

    public struct Contents: Sendable {
        public var profile: SystemProfile
        /// What the user was doing, in their words. Empty is allowed — a report with a log and no
        /// prose still beats no report.
        public var note: String
        /// Files to include verbatim, e.g. the host trace. Missing ones are skipped, and the
        /// manifest says so rather than pretending they were never asked for.
        public var attachments: [URL]

        public init(profile: SystemProfile, note: String = "", attachments: [URL] = []) {
            self.profile = profile
            self.note = note
            self.attachments = attachments
        }
    }

    public enum Failure: LocalizedError {
        case couldNotStage
        case couldNotArchive(String)

        public var errorDescription: String? {
            switch self {
            case .couldNotStage:
                "진단 파일을 모을 임시 폴더를 만들지 못했습니다."
            case let .couldNotArchive(reason):
                "진단 파일을 압축하지 못했습니다. (\(reason))"
            }
        }
    }

    /// Builds the zip and returns where it went.
    ///
    /// - Parameters:
    ///   - log: injected so the whole thing is testable without a log store. The default reads
    ///     this process's own entries, which needs no entitlement — `OSLogStore.local()` would.
    @discardableResult
    public static func write(
        _ contents: Contents,
        to destination: URL,
        log: () -> String = { recentLog() }
    ) throws -> URL {
        let staging = URL.temporaryDirectory.appending(path: "FCPCaption-diagnostics-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)) != nil else {
            throw Failure.couldNotStage
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        try Data(report(contents).utf8).write(to: staging.appending(path: "report.md"))
        try Data(log().utf8).write(to: staging.appending(path: "log.txt"))

        for attachment in contents.attachments where FileManager.default.fileExists(atPath: attachment.path) {
            try? FileManager.default.copyItem(
                at: attachment, to: staging.appending(path: attachment.lastPathComponent))
        }

        try archive(staging, to: destination)
        return destination
    }

    /// The human-readable half, also used as the issue body.
    public static func report(_ contents: Contents) -> String {
        var text = "## Environment\n\n\(contents.profile.markdown)\n"
        if !contents.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n## What happened\n\n\(contents.note)\n"
        }
        return text
    }

    // MARK: - Zipping

    /// `NSFileCoordinator`'s `.forUploading` is how a sandboxed app makes a zip: it hands back a
    /// temporary archive of the directory, and there is no `zip` binary to spawn.
    ///
    /// The archive it provides lives only for the duration of the block, so it is copied out
    /// inside — a URL captured and used afterwards points at a file that is already gone.
    private static func archive(_ directory: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(
            readingItemAt: directory, options: [.forUploading], error: &coordinatorError
        ) { archive in
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: archive, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw Failure.couldNotArchive(coordinatorError.localizedDescription) }
        if let copyError { throw Failure.couldNotArchive(copyError.localizedDescription) }
    }

    // MARK: - Log

    /// This process's own entries for our subsystem.
    ///
    /// `.currentProcessIdentifier` rather than `.system`: the system scope needs an entitlement we
    /// do not have and would not be given, while our own entries are the ones that say anything.
    public static func recentLog(hours: Int = 6, limit: Int = 4000) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-Double(hours) * 3600))
            let entries = try store.getEntries(
                at: since,
                matching: NSPredicate(format: "subsystem == %@", subsystem)
            )
            let formatter = ISO8601DateFormatter()
            let lines = entries
                .compactMap { $0 as? OSLogEntryLog }
                .suffix(limit)
                .map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.composedMessage)" }
            // An empty result is a fact about the log, not a failure to read it — say which.
            return lines.isEmpty ? "(no entries for \(subsystem) in the last \(hours)h)" : lines.joined(separator: "\n")
        } catch {
            // Never silently return "" here: an empty log file would read as "nothing went wrong".
            return "could not read the log: \(error.localizedDescription)"
        }
    }

    // MARK: - The issue

    /// A GitHub issue URL with the environment already filled in, so the user only writes the part
    /// they know and attaches the zip.
    public static func issueURL(
        repository: String = "jkh911208/fcp_ac",
        contents: Contents
    ) -> URL? {
        let body = """
        \(report(contents))

        ## Steps

        <!-- 무엇을 하다가 생겼는지 적어 주세요. -->

        ## Diagnostics

        <!-- 저장한 zip 파일을 이 아래에 끌어다 놓아 주세요. 로그와 위 표가 들어 있습니다. -->
        """
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        components?.queryItems = [URLQueryItem(name: "body", value: body)]
        return components?.url
    }
}
