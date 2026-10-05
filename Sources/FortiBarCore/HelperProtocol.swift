import Foundation

/// Wire protocol between the FortiBar app and the privileged helper
/// (`FortiBarHelper`, a root LaunchDaemon installed once).
///
/// One JSON object per line over a Unix socket; the helper replies with one
/// JSON line. The helper only accepts the three verbs below with validated
/// parameters. It never runs caller-supplied commands.
public enum HelperProtocol {
    public static let label = "com.fortibar.helper"
    public static let socketPath = "/var/run/fortibar-helper.sock"
    public static let installedBinary = "/Library/PrivilegedHelperTools/com.fortibar.helper"
    public static let launchDaemonPlist = "/Library/LaunchDaemons/com.fortibar.helper.plist"
    /// Bump when the protocol or helper behaviour changes; the app reinstalls
    /// the helper when the running version differs.
    public static let version = 1

    public static let charonCandidates = [
        "/opt/homebrew/opt/strongswan/libexec/ipsec/charon",
        "/usr/local/opt/strongswan/libexec/ipsec/charon",
    ]

    public static func locateCharon() -> String? {
        charonCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public struct HelperRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable { case ping, status, connect, disconnect }

    public var cmd: Command
    public var connect: ConnectParams?

    public init(cmd: Command, connect: ConnectParams? = nil) {
        self.cmd = cmd
        self.connect = connect
    }
}

public struct ConnectParams: Codable, Sendable {
    public var name: String
    public var gateway: String
    public var peerID: String
    public var username: String
    public var ike: String
    public var esp: String
    public var routes: [String]
    public var lanExceptions: [String]
    public var psk: String
    public var password: String
    public var otp: String

    public init(profile: NativeProfile, secrets: VPNSecrets) {
        name = profile.name
        gateway = profile.gateway
        peerID = profile.peerID
        username = profile.username
        ike = profile.ike
        esp = profile.esp
        routes = profile.routes
        lanExceptions = profile.lanExceptions
        psk = secrets.psk
        password = secrets.password
        otp = secrets.otp
    }
}

public struct HelperResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    /// `disconnected`, `connecting`, `connected`, `disconnecting`.
    public var state: String
    public var vip: String?
    public var message: String?
    public var warnings: [String]?
    public var log: [String]?
    // ping only
    public var version: Int?
    public var charonFound: Bool?

    public init(ok: Bool = true, error: String? = nil, state: String = "disconnected", vip: String? = nil,
                message: String? = nil, warnings: [String]? = nil, log: [String]? = nil,
                version: Int? = nil, charonFound: Bool? = nil) {
        self.ok = ok
        self.error = error
        self.state = state
        self.vip = vip
        self.message = message
        self.warnings = warnings
        self.log = log
        self.version = version
        self.charonFound = charonFound
    }
}

/// Strict validation of everything that reaches charon or `route`.
public enum HelperValidation {
    public struct Invalid: Error, CustomStringConvertible {
        public let description: String
    }

    private static let proposalTokens: Set<String> = [
        "aes128", "aes192", "aes256", "3des", "sha1", "sha256", "sha384", "sha512",
        "modp1024", "modp1536", "modp2048", "modp3072", "modp4096",
        "ecp256", "ecp384", "ecp521", "aes128gcm16", "aes256gcm16",
    ]

    public static func validate(_ p: ConnectParams) throws {
        try require(matches(p.gateway, #"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"#),
                    "The gateway must be an IPv4 address or a hostname.")
        try require(matches(p.username, #"^[A-Za-z0-9._@-]{1,128}$"#), "Invalid username.")
        try require(p.peerID.isEmpty || matches(p.peerID, #"^@?[A-Za-z0-9._:@-]{1,128}$"#), "Invalid peer ID.")
        try require(secret(p.psk), "The PSK is empty or contains control characters.")
        try require(secret(p.password), "The password is empty or contains control characters.")
        try require(matches(p.otp, #"^[0-9]{6}$"#), "The FortiToken code must be six digits.")
        for proposals in [p.ike, p.esp] {
            let list = proposals.split(separator: ",").map(String.init)
            try require(!list.isEmpty && list.count <= 32 && list.allSatisfy { entry in
                !entry.isEmpty && Set(entry.split(separator: "-").map(String.init)).isSubset(of: proposalTokens)
            }, "Unrecognised crypto proposal.")
        }
        try require(!p.routes.isEmpty && p.routes.count <= 64, "Provide at least one VPN subnet.")
        for cidr in p.routes + p.lanExceptions {
            try require(isIPv4CIDR(cidr), "Invalid subnet: \(cidr)")
        }
        try require(p.lanExceptions.count <= 64, "Too many LAN exceptions.")
    }

    public static func isIPv4CIDR(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (1 ... 32).contains(prefix) else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { part in
            guard let value = Int(part), (0 ... 255).contains(value) else { return false }
            return String(value) == part
        }
    }

    private static func secret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Invalid(description: message) }
    }
}

/// Builds the VICI messages that describe the FortiGate IKEv1 connection.
/// Mirrors the connection vpn-desk loads, with the adjustments that made the
/// macOS lab work: no secret owners (strongSwan looks XAUTH secrets up by IKE
/// ID, not by username), one connection attempt, no automatic re-initiation.
public enum ViciConfig {
    public static let connectionName = "fortibar"
    public static var childName: String { connectionName + "-net" }

    public static func connection(_ p: ConnectParams) -> ViciMessage {
        var local = ViciMessage(); local.set("auth", "psk")
        var xauth = ViciMessage(); xauth.set("auth", "xauth"); xauth.set("xauth_id", p.username)
        var remote = ViciMessage(); remote.set("auth", "psk")
        if !p.peerID.isEmpty { remote.set("id", p.peerID) }

        var child = ViciMessage()
        child.set("local_ts", list: ["dynamic"])
        child.set("remote_ts", list: ["0.0.0.0/0"])
        child.set("esp_proposals", list: p.esp.split(separator: ",").map(String.init))
        child.set("start_action", "none")
        child.set("dpd_action", "clear")
        var children = ViciMessage(); children.set(childName, section: child)

        var conn = ViciMessage()
        conn.set("version", "1")
        conn.set("aggressive", "yes")
        conn.set("remote_addrs", list: [p.gateway])
        conn.set("vips", list: ["0.0.0.0"])
        conn.set("pull", "yes")
        conn.set("proposals", list: p.ike.split(separator: ",").map(String.init))
        conn.set("dpd_delay", "30s")
        conn.set("keyingtries", "1")
        conn.set("local", section: local)
        conn.set("local-xauth", section: xauth)
        conn.set("remote", section: remote)
        conn.set("children", section: children)

        var root = ViciMessage()
        root.set(connectionName, section: conn)
        return root
    }

    /// Secret without owners matches any identity pair.
    public static func sharedSecret(id: String, type: String, data: String) -> ViciMessage {
        var m = ViciMessage()
        m.set("id", id)
        m.set("type", type)
        m.set("data", data)
        return m
    }

    public static let pskID = connectionName + "-psk"
    public static let xauthID = connectionName + "-xauth"

    public static let strongswanConf = """
    charon {
        install_routes = no
        install_virtual_ip = yes
        filelog {
            fortibar {
                path = %LOG%
                time_format = %H:%M:%S
                append = no
                default = 1
                ike = 2
                cfg = 2
                net = 1
                enc = 1
                knl = 1
            }
        }
        plugins {
            vici {
                socket = unix://%SOCKET%
            }
        }
    }

    """
}
