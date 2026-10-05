import Darwin
import FortiBarCore
import Foundation

extension Helper {
    // MARK: - Connect

    func connect(_ params: ConnectParams) -> HelperResponse {
        do { try HelperValidation.validate(params) } catch {
            return HelperResponse(ok: false, error: "\(error)", state: phase.rawValue)
        }
        guard operation.try() else {
            return HelperResponse(ok: false, error: "Another connect/disconnect is in progress.", state: phase.rawValue)
        }
        defer { operation.unlock() }
        guard phase == .idle else {
            return HelperResponse(ok: false, error: "A VPN connection is already active.", state: phase.rawValue)
        }

        phase = .connecting
        let secrets = [params.psk, params.password, params.password + params.otp, params.otp]
        var controlLog: [String] = []
        var warnings: [String] = []
        do {
            guard let charonPath = HelperProtocol.locateCharon() else {
                throw HelperError("strongSwan is not installed. Run: brew install strongswan")
            }
            try startCharon(path: charonPath)
            let vici = try ViciClient(path: viciSocket, timeout: 15)

            let stats = try vici.request("stats")
            let plugins = stats.list("plugins")
            for required in ["xauth-generic", "kernel-pfkey", "vici"] where !plugins.contains(required) {
                throw HelperError("strongSwan is missing the \(required) plugin. Reinstall it with Homebrew.")
            }

            do {
                try vici.command("load-conn", ViciConfig.connection(params))
            } catch {
                throw HelperError("strongSwan rejected the profile (is IKEv1 enabled in this build?): \(error)")
            }
            try vici.command("load-shared", ViciConfig.sharedSecret(id: ViciConfig.pskID, type: "IKE", data: params.psk))
            try vici.command("load-shared", ViciConfig.sharedSecret(
                id: ViciConfig.xauthID, type: "XAUTH", data: params.password + params.otp))

            var initiate = ViciMessage()
            initiate.set("ike", ViciConfig.connectionName)
            initiate.set("child", ViciConfig.childName)
            initiate.set("timeout", "45000")
            vici.setTimeout(70)
            log("initiating connection to \(params.gateway)")
            let response = try vici.stream("initiate", initiate, events: ["control-log"]) { _, event in
                if let line = event.string("msg") { controlLog.append(Self.mask(line, secrets)) }
            }
            vici.setTimeout(15)
            guard response.string("success") == "yes" else {
                throw HelperError(Self.explainFailure(response.string("errmsg"), log: controlLog))
            }

            // The XAUTH secret (password + one-time code) is only needed for the handshake.
            _ = try? vici.command("unload-shared", Self.idMessage(ViciConfig.xauthID))

            let sa = try readSA(vici)
            guard sa.installed, let vip = sa.vips.first else {
                throw HelperError("The tunnel came up without a virtual IP or child SA.")
            }
            guard let interface = interfaceName(forIPv4: vip) else {
                throw HelperError("Could not find the tunnel interface for \(vip).")
            }
            warnings = installRoutes(params, interface: interface, remoteHost: sa.remoteHost)

            self.vip = vip
            phase = .connected
            log("connected: \(vip) on \(interface), \(routes.count) routes")
            return HelperResponse(state: "connected", vip: vip, message: "Connected.", warnings: warnings.isEmpty ? nil : warnings)
        } catch {
            let reason = "\(error)"
            log("connect failed: \(reason)")
            var tail = controlLog.suffix(12).map { $0 }
            if tail.isEmpty, let text = try? String(contentsOfFile: charonLog, encoding: .utf8) {
                tail = text.split(separator: "\n").suffix(12).map { Self.mask(String($0), secrets) }
            }
            teardown()
            return HelperResponse(ok: false, error: Self.mask(reason, secrets), state: phase.rawValue, log: tail)
        }
    }

    // MARK: - Disconnect

    /// Caller must hold `operation`.
    func teardown() {
        phase = .disconnecting
        if charon?.isRunning == true, let vici = try? ViciClient(path: viciSocket, timeout: 10) {
            var terminate = ViciMessage()
            terminate.set("ike", ViciConfig.connectionName)
            terminate.set("force", "yes")
            terminate.set("timeout", "5000")
            _ = try? vici.stream("terminate", terminate, events: ["control-log"]) { _, _ in }
            _ = try? vici.command("unload-shared", Self.idMessage(ViciConfig.pskID))
            _ = try? vici.command("unload-shared", Self.idMessage(ViciConfig.xauthID))
            var unload = ViciMessage()
            unload.set("name", ViciConfig.connectionName)
            _ = try? vici.command("unload-conn", unload)
        }
        for route in routes.reversed() {
            let result = route.delete()
            if result.status != 0, !result.output.contains("not in table") {
                log("route delete \(route.destination) failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        routes = []
        stopCharon()
        clearPersisted()
        vip = nil
        phase = .idle
    }

    // MARK: - charon

    private func startCharon(path: String) throws {
        let others = runTool("/usr/bin/pgrep", ["-x", "charon"]).output
            .split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        if let foreign = others.first(where: { $0 != charon?.processIdentifier }) {
            throw HelperError("Another strongSwan daemon (charon, pid \(foreign)) is already running. Stop it first.")
        }

        let fm = FileManager.default
        try? fm.removeItem(atPath: workDirectory)
        try fm.createDirectory(atPath: workDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let conf = ViciConfig.strongswanConf
            .replacingOccurrences(of: "%LOG%", with: charonLog)
            .replacingOccurrences(of: "%SOCKET%", with: viciSocket)
        let confPath = workDirectory + "/strongswan.conf"
        fm.createFile(atPath: confPath, contents: Data(conf.utf8), attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: charonStderr, contents: nil, attributes: [.posixPermissions: 0o600])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.environment = ["STRONGSWAN_CONF": confPath, "PATH": "/usr/sbin:/usr/bin:/sbin:/bin"]
        process.standardInput = FileHandle.nullDevice
        let errorHandle = FileHandle(forWritingAtPath: charonStderr)
        process.standardOutput = errorHandle
        process.standardError = errorHandle
        try process.run()
        charon = process
        persist()

        for _ in 0 ..< 80 {
            if fm.fileExists(atPath: viciSocket) { return }
            if !process.isRunning {
                let detail = (try? String(contentsOfFile: charonStderr, encoding: .utf8)) ?? ""
                throw HelperError("charon exited immediately: \(detail.suffix(300))")
            }
            Thread.sleep(forTimeInterval: 0.125)
        }
        throw HelperError("charon did not open its control socket.")
    }

    private func stopCharon() {
        guard let process = charon else { return }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(8)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        charon = nil
    }

    // MARK: - SA / routes

    struct SAInfo {
        var installed = false
        var vips: [String] = []
        var remoteHost: String?
    }

    func readSA(_ vici: ViciClient) throws -> SAInfo {
        var info = SAInfo()
        var query = ViciMessage()
        query.set("ike", ViciConfig.connectionName)
        _ = try vici.stream("list-sas", query, events: ["list-sa"]) { _, event in
            guard let sa = event.section(ViciConfig.connectionName) else { return }
            info.vips = sa.list("local-vips")
            info.remoteHost = sa.string("remote-host")
            for (_, child) in sa.section("child-sas")?.sections ?? [] where child.string("state") == "INSTALLED" {
                info.installed = true
            }
        }
        return info
    }

    func tunnelIsUp() throws -> Bool {
        guard charon?.isRunning == true else { return false }
        return try readSA(try ViciClient(path: viciSocket, timeout: 8)).installed
    }

    /// LAN exceptions are pinned to their current path first, then the VPN
    /// subnets are routed through the tunnel interface. Returns warnings for
    /// routes that could not be installed (e.g. already owned by someone else).
    private func installRoutes(_ params: ConnectParams, interface: String, remoteHost: String?) -> [String] {
        var warnings: [String] = []
        var exceptions = params.lanExceptions
        if let remoteHost, HelperValidation.isIPv4CIDR(remoteHost + "/32") { exceptions.append(remoteHost + "/32") }

        var planned: [RouteSpec] = []
        for cidr in Array(NSOrderedSet(array: exceptions)) as? [String] ?? exceptions {
            let path = currentRoute(to: networkAddress(of: cidr))
            guard path.gateway != nil || path.interface != nil else {
                warnings.append("No local path for LAN exception \(cidr); skipped.")
                continue
            }
            planned.append(RouteSpec(destination: cidr, gateway: path.gateway,
                                     interface: path.gateway == nil ? path.interface : nil))
        }
        for cidr in params.routes where !exceptions.contains(cidr) {
            planned.append(RouteSpec(destination: cidr, gateway: nil, interface: interface))
        }

        for route in planned {
            let result = route.add()
            if result.status == 0 {
                routes.append(route)
                persist()
            } else {
                let reason = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                warnings.append("Route \(route.destination) not installed: \(reason)")
                log("route add \(route.destination) failed: \(reason)")
            }
        }
        return warnings
    }

    // MARK: - Messages

    static func idMessage(_ id: String) -> ViciMessage {
        var message = ViciMessage()
        message.set("id", id)
        return message
    }

    static func mask(_ text: String, _ secrets: [String]) -> String {
        var result = text
        for secret in secrets.sorted(by: { $0.count > $1.count }) where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: "***")
        }
        return result
    }

    static func explainFailure(_ errmsg: String?, log: [String]) -> String {
        let text = log.joined(separator: "\n")
        if text.contains("no XAuth password found") {
            return "The XAUTH password could not be matched to this connection."
        }
        if text.contains("giving up after") || text.contains("retransmit") && !text.contains("received packet") {
            return "The gateway did not respond. Check the gateway address and your network."
        }
        if text.contains("received packet") {
            return "Authentication failed or timed out. Check the password and use a fresh FortiToken code (a code can only be used once)."
        }
        return errmsg ?? "Connection failed."
    }
}
