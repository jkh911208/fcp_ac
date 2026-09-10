import Foundation
import os

/// Asks GitHub whether a newer release exists. Nothing more.
///
/// **This is the only network request the app makes besides the model download**, and it is worth
/// being precise about what it costs the user: an unauthenticated GET to a public endpoint. No
/// account, no identifier, no telemetry — GitHub learns an IP address made a request, the way it
/// would if the user opened the releases page in a browser. It is a setting, and it can be off.
///
/// It deliberately cannot install anything. The extension is sandboxed and cannot replace
/// `/Applications/FCPCaption.app`; an updater that pretends otherwise would fail in a way the user
/// could not act on. This says a version exists and offers the page.
public struct UpdateCheck: Sendable {
    private static let log = Logger(subsystem: "com.jkh911208.FCPCaption", category: "update")

    public struct Release: Sendable, Equatable {
        /// Without the leading `v`, so it reads the way the app's own version does.
        public var version: String
        public var url: URL

        public init(version: String, url: URL) {
            self.version = version
            self.url = url
        }
    }

    public var repository: String
    public var session: URLSession

    public init(repository: String = "jkh911208/fcp_ac", session: URLSession = .shared) {
        self.repository = repository
        self.session = session
    }

    /// The published release, if there is one newer than `current`.
    ///
    /// Returns nil for "nothing newer" **and** for every failure. A person who cannot reach GitHub
    /// has nothing to do about it, and an error banner over a working panel is noise — so failures
    /// go to the log, where a bug report can pick them up, and nowhere else.
    public func newerRelease(than current: String) async -> Release? {
        do {
            guard let release = try await latest() else { return nil }
            guard Self.isNewer(release.version, than: current) else {
                Self.log.notice("up to date (\(current, privacy: .public))")
                return nil
            }
            Self.log.notice("""
                update available: \(release.version, privacy: .public) \
                (running \(current, privacy: .public))
                """)
            return release
        } catch {
            Self.log.notice("update check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// - Returns: nil when the repository has no published release yet, which is not an error.
    func latest() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            // 404 is what an unreleased repository answers. Everything else is worth logging.
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
        }

        struct Payload: Decodable {
            var tag_name: String
            var html_url: String
            var draft: Bool?
            var prerelease: Bool?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.draft != true, payload.prerelease != true else { return nil }
        guard let url = URL(string: payload.html_url) else { throw Failure.malformed }
        return Release(version: Self.normalized(payload.tag_name), url: url)
    }

    enum Failure: LocalizedError {
        case http(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case let .http(code): "GitHub이 \(code)로 응답했습니다."
            case .malformed: "릴리스 정보를 이해하지 못했습니다."
            }
        }
    }

    // MARK: - Versions

    static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Numeric, component by component — so 0.1.10 is newer than 0.1.9, which a string comparison
    /// gets backwards.
    ///
    /// Anything non-numeric makes the answer false rather than a guess: refusing to compare is a
    /// missed notification, while comparing wrongly offers a "newer" version that is older.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = parse(candidate), let old = parse(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func parse(_ version: String) -> [Int]? {
        let parts = normalized(version).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        return numbers
    }
}
