import Foundation
import Testing
@testable import FCPCaptionCore

/// Never reaches GitHub. Every response here is served by a `URLProtocol` stub, per the repo rule
/// that a test must not hit a real API.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var error: (any Error)?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        status = 200; body = Data(); error = nil; lastRequest = nil
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@Suite("comparing versions", .serialized)
struct VersionOrderTests {
    @Test("a later patch, minor or major is newer")
    func ordersNormally() {
        #expect(UpdateCheck.isNewer("0.1.3", than: "0.1.2"))
        #expect(UpdateCheck.isNewer("0.2.0", than: "0.1.9"))
        #expect(UpdateCheck.isNewer("1.0.0", than: "0.9.9"))
    }

    @Test("0.1.10 is newer than 0.1.9 — the comparison a string gets backwards")
    func doesNotCompareAsText() {
        #expect(UpdateCheck.isNewer("0.1.10", than: "0.1.9"))
        #expect(!UpdateCheck.isNewer("0.1.9", than: "0.1.10"))
    }

    @Test("the same version, and an older one, are not newer")
    func rejectsSameAndOlder() {
        #expect(!UpdateCheck.isNewer("0.1.2", than: "0.1.2"))
        #expect(!UpdateCheck.isNewer("0.1.1", than: "0.1.2"))
    }

    @Test("a leading v on either side changes nothing")
    func ignoresTheTagPrefix() {
        #expect(UpdateCheck.isNewer("v0.1.3", than: "0.1.2"))
        #expect(!UpdateCheck.isNewer("v0.1.2", than: "v0.1.2"))
    }

    @Test("missing components count as zero")
    func padsShortVersions() {
        #expect(UpdateCheck.isNewer("0.2", than: "0.1.9"))
        #expect(!UpdateCheck.isNewer("0.1", than: "0.1.0"))
    }

    @Test("a version it cannot parse is never called newer")
    func refusesToGuess() {
        // Offering a "newer" version that is actually older is worse than missing a notification.
        #expect(!UpdateCheck.isNewer("0.2.0-beta", than: "0.1.2"))
        #expect(!UpdateCheck.isNewer("nightly", than: "0.1.2"))
        #expect(!UpdateCheck.isNewer("0.1.3", than: "unknown"))
    }
}

@Suite("asking GitHub", .serialized)
struct UpdateCheckNetworkTests {
    private func check() -> UpdateCheck {
        StubProtocol.reset()
        return UpdateCheck(repository: "jkh911208/fcp_ac", session: StubProtocol.session)
    }

    private static func payload(tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/jkh911208/fcp_ac/releases/tag/\(tag)",
         "draft":\(draft),"prerelease":\(prerelease)}
        """.utf8)
    }

    @Test("a newer release comes back with its page")
    func reportsANewerRelease() async {
        let subject = check()
        StubProtocol.body = Self.payload(tag: "v0.1.3")
        let release = await subject.newerRelease(than: "0.1.2")
        #expect(release?.version == "0.1.3")
        #expect(release?.url.absoluteString.hasSuffix("/releases/tag/v0.1.3") == true)
    }

    @Test("it asks the releases endpoint for this repository, and nothing else")
    func requestsTheRightThing() async {
        let subject = check()
        StubProtocol.body = Self.payload(tag: "v0.1.3")
        _ = await subject.newerRelease(than: "0.1.2")
        let request = StubProtocol.lastRequest
        #expect(request?.url?.absoluteString == "https://api.github.com/repos/jkh911208/fcp_ac/releases/latest")
        // No credential, no identifier: nothing about the user is in this request.
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request?.httpBody == nil)
    }

    @Test("the same version reports nothing")
    func staysQuietWhenCurrent() async {
        let subject = check()
        StubProtocol.body = Self.payload(tag: "v0.1.2")
        #expect(await subject.newerRelease(than: "0.1.2") == nil)
    }

    @Test("a draft or a pre-release is not offered")
    func ignoresDraftsAndPrereleases() async {
        var subject = check()
        StubProtocol.body = Self.payload(tag: "v0.2.0", draft: true)
        #expect(await subject.newerRelease(than: "0.1.2") == nil)

        subject = check()
        StubProtocol.body = Self.payload(tag: "v0.2.0", prerelease: true)
        #expect(await subject.newerRelease(than: "0.1.2") == nil)
    }

    @Test("a repository with no release yet is not an error")
    func handlesNoReleases() async {
        let subject = check()
        StubProtocol.status = 404
        #expect(await subject.newerRelease(than: "0.1.2") == nil)
    }

    @Test("being offline reports nothing, and never throws into the panel")
    func failsQuietly() async {
        let subject = check()
        StubProtocol.error = URLError(.notConnectedToInternet)
        #expect(await subject.newerRelease(than: "0.1.2") == nil)
    }

    @Test("a rate limit or a broken body reports nothing")
    func survivesBadResponses() async {
        var subject = check()
        StubProtocol.status = 403
        #expect(await subject.newerRelease(than: "0.1.2") == nil)

        subject = check()
        StubProtocol.body = Data("not json".utf8)
        #expect(await subject.newerRelease(than: "0.1.2") == nil)
    }
}
