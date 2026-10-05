import Foundation

/// Installs/removes the privileged helper. Needs administrator rights once
/// (the system prompt accepts Touch ID); after that connecting never does.
public enum HelperInstaller {
    public static func bundledHelper() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("FortiBarHelper"),
            // Development: `swift build` places both products side by side.
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("FortiBarHelper"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func bundledScript() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("install-helper.sh"),
           FileManager.default.isReadableFile(atPath: bundled.path) {
            return bundled
        }
        // Development (`swift run`): walk up from the executable to the repo's Scripts folder.
        var directory = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0 ..< 6 {
            guard let current = directory else { break }
            let candidate = current.appendingPathComponent("Scripts/install-helper.sh")
            if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
            directory = current.deletingLastPathComponent()
        }
        return nil
    }

    public static func install() throws {
        guard let helper = bundledHelper() else {
            throw VPNError(message: "The helper binary was not found inside the app.")
        }
        try runElevated(["install", helper.path, String(getuid())])
    }

    public static func uninstall() throws {
        try runElevated(["uninstall"])
    }

    private static func runElevated(_ arguments: [String]) throws {
        guard let script = bundledScript() else {
            throw VPNError(message: "The helper install script was not found.")
        }
        let parts = [script.path] + arguments
        guard !parts.contains(where: { $0.contains("'") || $0.contains("\"") || $0.contains("\\") }) else {
            throw VPNError(message: "The install path contains unsupported characters.")
        }
        let shell = "/bin/sh " + parts.map { "'\($0)'" }.joined(separator: " ")
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", "do shell script \"\(shell)\" with administrator privileges"]
        let err = Pipe()
        osa.standardError = err
        osa.standardOutput = Pipe()
        try osa.run()
        osa.waitUntilExit()
        if osa.terminationStatus != 0 {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if text.contains("-128") { throw VPNError(message: "Installation cancelled.") }
            throw VPNError(message: "Helper installation failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
