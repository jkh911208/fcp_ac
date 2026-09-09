import Foundation

/// What a bug report needs to be actionable, and nothing else.
///
/// Deliberately a plain value with an explicit initialiser: the machine-reading half is one
/// function, so everything below it can be tested without a Mac of a particular shape.
///
/// **Nothing here identifies a person.** No name, no serial number, no hostname, no file paths,
/// no library contents. A bug report is a favour the user is doing us, and it should not cost them
/// anything they would not have typed themselves.
public struct SystemProfile: Sendable, Equatable {
    /// `hw.model`, e.g. `Mac16,6`. The marketing name is not readable without a lookup table that
    /// would be stale the week a new Mac ships, so the identifier is what gets reported.
    public var macModel: String
    /// `machdep.cpu.brand_string`, e.g. `Apple M4 Pro`.
    public var cpu: String
    public var performanceCores: Int
    public var efficiencyCores: Int
    /// Bytes.
    public var memory: Int64
    /// e.g. `15.6.1`.
    public var macOSVersion: String
    /// The build, e.g. `24G90`. Worth having separately: the Neural Engine cache is keyed to it.
    public var macOSBuild: String
    /// FCPCaption's own version.
    public var appVersion: String
    /// What the ProExtension host says it is, e.g. `Final Cut Pro 12.3`. Nil when the panel is
    /// running outside Final Cut Pro, which is itself worth seeing in a report.
    public var host: String?

    public init(
        macModel: String,
        cpu: String,
        performanceCores: Int,
        efficiencyCores: Int,
        memory: Int64,
        macOSVersion: String,
        macOSBuild: String,
        appVersion: String,
        host: String?
    ) {
        self.macModel = macModel
        self.cpu = cpu
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.memory = memory
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.appVersion = appVersion
        self.host = host
    }

    // MARK: - Reading this Mac

    /// - Parameters:
    ///   - host: supplied by the caller, because only the extension can ask the ProExtension host.
    ///   - bundle: where the app version comes from.
    public static func current(host: String?, bundle: Bundle = .main) -> SystemProfile {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return SystemProfile(
            macModel: sysctlString("hw.model") ?? "unknown",
            cpu: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            // perflevel0 is the performance cluster, perflevel1 the efficiency one. A Mac with a
            // single cluster has no perflevel1 at all, which reads correctly as zero.
            performanceCores: Int(sysctlInteger("hw.perflevel0.logicalcpu") ?? 0),
            efficiencyCores: Int(sysctlInteger("hw.perflevel1.logicalcpu") ?? 0),
            memory: sysctlInteger("hw.memsize") ?? 0,
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            macOSBuild: sysctlString("kern.osversion") ?? "unknown",
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            host: host
        )
    }

    /// `sysctlbyname` rather than running `sysctl`: a sandboxed extension cannot spawn a process,
    /// and this needs no entitlement at all.
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    static func sysctlInteger(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    // MARK: - Reporting

    /// A markdown table, because it is pasted into a GitHub issue.
    public var markdown: String {
        var rows: [(String, String)] = [
            ("FCPCaption", appVersion),
            ("Host", host ?? "not running inside Final Cut Pro"),
            ("macOS", "\(macOSVersion) (\(macOSBuild))"),
            ("Mac", macModel),
            ("CPU", cpu),
        ]
        if performanceCores > 0 || efficiencyCores > 0 {
            rows.append(("Cores", "\(performanceCores)P + \(efficiencyCores)E"))
        }
        if memory > 0 {
            rows.append(("Memory", Self.gigabytes(memory)))
        }
        let body = rows.map { "| \($0.0) | \($0.1) |" }.joined(separator: "\n")
        return """
        | | |
        |---|---|
        \(body)
        """
    }

    static func gigabytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb.rounded() == gb ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb)
    }
}
