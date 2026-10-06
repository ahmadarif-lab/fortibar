import Foundation

/// Installs an update the way FortiBar is distributed: `brew upgrade` of the
/// ahmadarif-lab/tap/fortibar cask. Homebrew is the only external tool the
/// app ever runs, and only when you click Install on an update.
public enum BrewUpgrade {
    public static let cask = "ahmadarif-lab/tap/fortibar"

    static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    public static let caskroomCandidates = ["/opt/homebrew/Caskroom/fortibar", "/usr/local/Caskroom/fortibar"]
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// The cask's Caskroom entry exists under either Homebrew prefix. A DMG
    /// copied into /Applications by hand has none, and is sent to the release page.
    public static func installedViaHomebrew(
        caskrooms: [String] = caskroomCandidates,
        fileManager: FileManager = .default
    ) -> Bool {
        caskrooms.contains { fileManager.fileExists(atPath: $0) }
    }

    static func brewPath(candidates: [String] = brewCandidates, fileManager: FileManager = .default) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// brew's own `Error: …` line rather than its whole transcript, otherwise
    /// the last line it printed.
    public static func summarize(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let line = lines.last { $0.hasPrefix("Error:") } ?? lines.last
        return line ?? "Homebrew failed without saying why."
    }

    /// Runs `brew <args>` and returns its output; a non-zero exit throws a
    /// `VPNError` carrying brew's own error line.
    public static func run(_ args: [String]) async throws -> String {
        guard let brew = brewPath() else {
            throw VPNError(message: "Homebrew was not found. Download FortiBar.dmg from the release page instead.")
        }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = args
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = searchPath
            environment["HOMEBREW_NO_ENV_HINTS"] = "1"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            // One pipe for both streams, read while the process runs: waiting
            // for exit first deadlocks once brew writes more than the pipe
            // buffer holds, which `brew update` can.
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else { throw VPNError(message: summarize(output)) }
            return output
        }.value
    }
}
