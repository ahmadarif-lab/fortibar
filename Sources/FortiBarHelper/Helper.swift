import Darwin
import FortiBarCore
import Foundation

/// The privileged daemon. Serves the app over a Unix socket (owner only),
/// owns the charon process and every system change made for a connection.
final class Helper: @unchecked Sendable {
    enum Phase: String { case idle = "disconnected", connecting, connected, disconnecting }

    let allowedUID: uid_t
    let workDirectory = "/var/run/fortibar"
    var viciSocket: String { workDirectory + "/charon.vici" }
    var charonLog: String { workDirectory + "/charon.log" }
    var charonStderr: String { workDirectory + "/charon.stderr" }
    var stateFile: String { workDirectory + "/state.json" }

    /// Serializes connect/disconnect/teardown.
    let operation = NSLock()
    private let stateLock = NSLock()
    private var _phase: Phase = .idle
    private var _vip: String?

    // Touched only while holding `operation`.
    var charon: Process?
    var routes: [RouteSpec] = []

    init(allowedUID: uid_t) {
        self.allowedUID = allowedUID
    }

    var phase: Phase {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _phase }
        set { stateLock.lock(); _phase = newValue; stateLock.unlock() }
    }

    var vip: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _vip }
        set { stateLock.lock(); _vip = newValue; stateLock.unlock() }
    }

    func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] \(line)\n".utf8))
    }

    // MARK: - Lifecycle

    func run() {
        log("FortiBarHelper \(HelperProtocol.version) starting for uid \(allowedUID)")
        recoverStaleState()
        installSignalHandlers()
        startMonitor()
        serve()
    }

    private var signalSources: [DispatchSourceSignal] = []

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [self] in
                log("signal \(signalNumber): tearing down")
                operation.lock()
                teardown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Server

    private func serve() {
        unlink(HelperProtocol.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { log("socket() failed"); exit(1) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(HelperProtocol.socketPath.utf8)
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { pointer in
                for (index, byte) in bytes.enumerated() { pointer[index] = byte }
                pointer[bytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { log("bind failed: \(String(cString: strerror(errno)))"); exit(1) }
        chown(HelperProtocol.socketPath, allowedUID, 0)
        chmod(HelperProtocol.socketPath, 0o600)
        guard listen(fd, 8) == 0 else { log("listen failed"); exit(1) }
        log("listening on \(HelperProtocol.socketPath)")

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            DispatchQueue.global().async { [self] in
                handle(client)
                close(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == allowedUID || uid == 0 else { return }
        UnixSocket.setTimeout(client, 120)
        guard let line = UnixSocket.readLine(client),
              let request = try? JSONDecoder().decode(HelperRequest.self, from: Data(line))
        else {
            reply(client, HelperResponse(ok: false, error: "Malformed request.", state: phase.rawValue))
            return
        }
        reply(client, dispatch(request))
    }

    private func reply(_ client: Int32, _ response: HelperResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        _ = UnixSocket.writeAll(client, Array(data) + [10])
    }

    private func dispatch(_ request: HelperRequest) -> HelperResponse {
        switch request.cmd {
        case .ping:
            return HelperResponse(state: phase.rawValue, vip: vip, version: HelperProtocol.version,
                                  charonFound: HelperProtocol.locateCharon() != nil)
        case .status:
            return HelperResponse(state: phase.rawValue, vip: vip)
        case .connect:
            guard let params = request.connect else {
                return HelperResponse(ok: false, error: "Missing connection parameters.", state: phase.rawValue)
            }
            return connect(params)
        case .disconnect:
            operation.lock()
            defer { operation.unlock() }
            teardown()
            return HelperResponse(state: phase.rawValue, message: "Disconnected.")
        }
    }

    // MARK: - Monitor

    /// Notices a tunnel that died (DPD, gateway restart) and cleans up routes
    /// and charon so the Mac is never left half-configured.
    private func startMonitor() {
        let thread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 4)
                guard phase == .connected, operation.try() else { continue }
                defer { operation.unlock() }
                guard phase == .connected else { continue }
                if (try? tunnelIsUp()) != true {
                    log("tunnel is down; cleaning up")
                    teardown()
                }
            }
        }
        thread.name = "monitor"
        thread.start()
    }

    // MARK: - Persistence / recovery

    private struct PersistedState: Codable {
        var charonPID: Int32?
        var routes: [RouteSpec]
    }

    func persist() {
        let state = PersistedState(charonPID: charon.map { $0.processIdentifier }, routes: routes)
        guard let data = try? JSONEncoder().encode(state) else { return }
        FileManager.default.createFile(atPath: stateFile, contents: data, attributes: [.posixPermissions: 0o600])
    }

    func clearPersisted() {
        unlink(stateFile)
    }

    /// After a crash/kill the previous run's charon and routes may linger.
    private func recoverStaleState() {
        guard let data = FileManager.default.contents(atPath: stateFile),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        log("recovering stale state")
        for route in state.routes.reversed() { _ = route.delete() }
        if let pid = state.charonPID, pid > 1 {
            let command = runTool("/bin/ps", ["-p", String(pid), "-o", "comm="]).output
            if command.contains("charon") { kill(pid, SIGTERM) }
        }
        clearPersisted()
    }
}
