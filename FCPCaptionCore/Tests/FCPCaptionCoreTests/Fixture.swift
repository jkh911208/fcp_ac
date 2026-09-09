import Foundation

/// Fixtures live at the repo root, not inside the package, because they are real Final Cut Pro
/// exports the whole project reads — not test resources. Resolved from this file's own path so it
/// works from any working directory, in Xcode and in CI alike.
enum Fixture {
    static let directory: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()   // FCPCaptionCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // FCPCaptionCore
        .deletingLastPathComponent()   // repo root
        .appending(path: "Fixtures")

    static func url(_ name: String) -> URL { directory.appending(path: name) }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    /// The fixture with the editor's own caption removed — the ordinary case, a clip with no
    /// captions on it yet. Placement rules are tested against this; the rules about *not* stepping
    /// on existing captions are tested against the fixture as it really is.
    static func withoutCaptions(_ name: String) throws -> Data {
        let document = try XMLDocument(data: try data(name), options: [.nodePreserveWhitespace])
        for caption in try document.nodes(forXPath: "//caption").compactMap({ $0 as? XMLElement }) {
            caption.detach()
        }
        document.isStandalone = false
        return document.xmlData(options: [.nodePrettyPrint])
    }

    /// Final Cut Pro ships the DTD for every FCPXML version it speaks. Validating our output
    /// against Apple's own grammar beats any amount of eyeballing — but it exists only where FCP
    /// is installed, so tests using it are skipped (visibly) elsewhere rather than passing blind.
    enum DTD {
        static let sourceURL = URL(filePath:
            "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_14.dtd")

        static var isAvailable: Bool { FileManager.default.isReadableFile(atPath: sourceURL.path) }

        /// Returns nil when the document is valid, or xmllint's complaint when it isn't.
        static func validate(_ document: Data) throws -> String? {
            let scratch = URL(filePath: NSTemporaryDirectory())
                .appending(path: "fcpcaption-dtd-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }

            // Copied out of the app bundle: libxml cannot resolve a DTD from inside it.
            let dtd = scratch.appending(path: "fcpxml.dtd")
            try FileManager.default.copyItem(at: sourceURL, to: dtd)
            let xml = scratch.appending(path: "document.fcpxml")
            try document.write(to: xml)

            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xmllint")
            process.arguments = ["--noout", "--dtdvalid", dtd.path, xml.path]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            try process.run()
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus == 0 { return nil }
            return String(decoding: output, as: UTF8.self)
        }
    }
}
