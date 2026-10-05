import Foundation

public struct VPNError: Error, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

/// Secrets for a single connection attempt. PSK and password come from the
/// keychain; the FortiToken code is typed each time and never persisted.
public struct VPNSecrets: Sendable, Equatable {
    public var psk: String
    public var password: String
    public var otp: String

    public init(psk: String = "", password: String = "", otp: String = "") {
        self.psk = psk
        self.password = password
        self.otp = otp
    }
}

public struct VPNStatus: Sendable, Equatable {
    public enum State: String, Sendable {
        case connected, connecting, disconnecting, disconnected, unknown
    }

    public var state: State
    public var address: String?

    public init(state: State, address: String? = nil) {
        self.state = state
        self.address = address
    }
}

/// A VPN profile. Secrets are deliberately **not** part of this type; they
/// live in the keychain (`SecretStore`).
public struct NativeProfile: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var gateway: String
    public var peerID: String
    public var username: String
    public var routes: [String]
    public var lanExceptions: [String]
    public var ike: String
    public var esp: String

    public init(
        id: String = UUID().uuidString,
        name: String,
        gateway: String,
        peerID: String,
        username: String,
        routes: [String] = NativeProfile.defaultRoutes,
        lanExceptions: [String] = [],
        ike: String = NativeProfile.defaultIKE,
        esp: String = NativeProfile.defaultESP
    ) {
        self.id = id
        self.name = name
        self.gateway = gateway
        self.peerID = peerID
        self.username = username
        self.routes = routes
        self.lanExceptions = lanExceptions
        self.ike = ike
        self.esp = esp
    }

    /// A new profile with sane FortiGate defaults (same proposals vpn-desk uses).
    public static func fresh(name: String = "New VPN") -> NativeProfile {
        NativeProfile(name: name, gateway: "", peerID: "", username: "",
                      lanExceptions: [])
    }

    public static let defaultRoutes = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

    public static let defaultIKE =
        "aes128-sha256-modp1536,aes256-sha256-modp1536,aes128-sha1-modp1536," +
        "aes256-sha1-modp1536,aes128-sha256-modp1024,aes256-sha256-modp1024," +
        "aes128-sha1-modp1024,aes256-sha1-modp1024,3des-sha1-modp1024"

    public static let defaultESP =
        "aes128-sha256-modp1536,aes256-sha256-modp1536,aes128-sha1-modp1536," +
        "aes256-sha1-modp1536,aes128-sha256-modp2048,aes256-sha256-modp2048," +
        "aes128-sha256-modp1024,aes256-sha256-modp1024,aes128-sha256,aes256-sha256," +
        "aes128-sha1,aes256-sha1,3des-sha1"
}
