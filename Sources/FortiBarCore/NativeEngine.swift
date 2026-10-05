import Foundation

/// Talks to the privileged helper over its Unix socket. One request per
/// connection, one JSON line each way.
public struct HelperClient: Sendable {
    public init() {}

    public func send(_ request: HelperRequest, timeout: TimeInterval = 10) throws -> HelperResponse {
        let fd: Int32
        do { fd = try UnixSocket.connect(path: HelperProtocol.socketPath) } catch {
            throw VPNError(message: "The FortiBar helper is not installed or not running.")
        }
        defer { close(fd) }
        UnixSocket.setTimeout(fd, timeout)
        let payload = try JSONEncoder().encode(request) + [10]
        guard UnixSocket.writeAll(fd, Array(payload)) else {
            throw VPNError(message: "Failed to send the command to the helper.")
        }
        guard let line = UnixSocket.readLine(fd) else {
            throw VPNError(message: "The helper did not respond.")
        }
        return try JSONDecoder().decode(HelperResponse.self, from: Data(line))
    }

    /// Nil when the helper is not reachable.
    public func ping() -> HelperResponse? {
        try? send(HelperRequest(cmd: .ping), timeout: 3)
    }
}

public enum HelperStatus: Equatable, Sendable {
    case notInstalled
    case outdated
    case missingStrongSwan
    case ready

    public var message: String? {
        switch self {
        case .notInstalled: return "The helper is not installed. Open Settings → General → Install helper (one time only)."
        case .outdated: return "The helper needs an update. Open Settings → General → Update helper."
        case .missingStrongSwan: return "strongSwan is not installed. Run: brew install strongswan"
        case .ready: return nil
        }
    }
}

/// FortiGate IKEv1 engine. All privileged work (charon, kernel SAs, routes)
/// happens in the helper, so connecting needs no sudo/Touch ID: only the
/// FortiToken code.
public final class NativeEngine: @unchecked Sendable {
    private let client = HelperClient()

    public init() {}

    public func helperStatus() -> HelperStatus {
        guard let pong = client.ping() else { return .notInstalled }
        if pong.version != HelperProtocol.version { return .outdated }
        if pong.charonFound != true { return .missingStrongSwan }
        return .ready
    }

    public func status() throws -> VPNStatus {
        status(from: try client.send(HelperRequest(cmd: .status)))
    }

    public func up(profile: NativeProfile, secrets: VPNSecrets) throws -> VPNStatus {
        let params = ConnectParams(profile: profile, secrets: secrets)
        let response = try client.send(HelperRequest(cmd: .connect, connect: params), timeout: 90)
        guard response.ok else {
            throw VPNError(message: response.error ?? "Connection failed.")
        }
        return status(from: response)
    }

    public func down() throws -> VPNStatus {
        status(from: try client.send(HelperRequest(cmd: .disconnect), timeout: 40))
    }

    private func status(from response: HelperResponse) -> VPNStatus {
        VPNStatus(state: VPNStatus.State(rawValue: response.state) ?? .unknown, address: response.vip)
    }
}
