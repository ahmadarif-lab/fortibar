import Foundation

/// Models mirroring the `fortivpn --json` output.
public struct VPNStatus: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case connected
        case connecting
        case disconnecting
        case disconnected
        case unknown
    }

    public var state: String
    public var profile: String?
    public var addresses: [String]?
    public var username: String?
    public var type: String?
    public var backend: String?

    public var parsedState: State { State(rawValue: state) ?? .unknown }
    public var isConnected: Bool { parsedState == .connected }
    public var primaryAddress: String? { addresses?.first }
}

public struct VPNProfile: Codable, Sendable, Identifiable {
    public var name: String
    public var kind: String?
    public var ikeVersion: Int?
    public var server: String?
    public var username: String?

    public var id: String { name }
}

public struct DoctorCheck: Codable, Sendable, Identifiable {
    public var name: String
    public var status: String
    public var message: String

    public init(name: String, status: String, message: String) {
        self.name = name
        self.status = status
        self.message = message
    }

    public var id: String { name }
    public var isWarning: Bool { status != "ok" }
}

public struct FortiVPNError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Thin wrapper around the `fortivpn` CLI (MIT, a3660980/fortivpn-client-cli),
/// which drives FortiClient through FortiTray's control socket.
public final class FortiVPNClient: @unchecked Sendable {
    public let binary: URL

    public init(binary: URL) {
        self.binary = binary
    }

    /// Resolve the CLI: bundled copy first, then common install locations.
    public static func locate() -> FortiVPNClient? {
        var candidates: [URL] = []
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("fortivpn"))
        }
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/fortivpn"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/fortivpn"))
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return FortiVPNClient(binary: url)
        }
        return nil
    }

    /// FortiClient 7.4.x keeps the tray deeper than the path the bundled CLI
    /// defaults to, so the CLI cannot restart it on its own. Point it there.
    public static let trayAppPath =
        "/Applications/FortiClient.app/Contents/Resources/runtime.helper/FortiClientAgent.app/Contents/Resources/FortiTray/FortiTray.app"

    private func run(_ arguments: [String], timeout: TimeInterval = 20) throws -> Data {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        // Never let the CLI pop GUI update prompts from inside the app.
        var env = ProcessInfo.processInfo.environment
        env["FORTIVPN_NO_UPDATE_CHECK"] = "1"
        if FileManager.default.fileExists(atPath: Self.trayAppPath) {
            env["FORTIVPN_FORTITRAY_APP"] = Self.trayAppPath
        }
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()

        // Read on a background queue so a chatty child can't deadlock the pipe.
        let collected = NSMutableData()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            collected.append(out.fileHandleForReading.readDataToEndOfFile())
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw FortiVPNError(message: "fortivpn \(arguments.first ?? "") timed out")
        }
        process.waitUntilExit()

        return collected as Data
    }

    private func decode<T: Decodable>(_ type: T.Type, from arguments: [String], timeout: TimeInterval = 20) throws -> T {
        let data = try run(arguments, timeout: timeout)
        guard !data.isEmpty else {
            throw FortiVPNError(message: "fortivpn \(arguments.joined(separator: " ")) returned no output")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw FortiVPNError(message: "cannot parse fortivpn output: \(raw.prefix(200))")
        }
    }

    public func status(profile: String? = nil) throws -> VPNStatus {
        var args = ["status", "--json"]
        if let profile { args += ["--profile", profile] }
        return try decode(VPNStatus.self, from: args, timeout: 12)
    }

    public func profiles() throws -> [VPNProfile] {
        try decode([VPNProfile].self, from: ["profiles", "--json"])
    }

    public func doctor() throws -> [DoctorCheck] {
        try decode([DoctorCheck].self, from: ["doctor", "--json"])
    }

    /// Blocking connect. FortiTray shows the FortiToken/SAML prompt itself, so
    /// this can legitimately wait for a human for a while.
    public func up(profile: String, timeout: TimeInterval = 120) throws -> VPNStatus {
        try decode(
            VPNStatus.self,
            from: ["up", "--profile", profile, "--timeout", String(Int(timeout)), "--json"],
            timeout: timeout + 20
        )
    }

    public func down(profile: String) throws -> VPNStatus {
        try decode(VPNStatus.self, from: ["down", "--profile", profile, "--json"])
    }
}
