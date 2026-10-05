import Darwin
import Foundation

struct HelperError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct ToolResult {
    let status: Int32
    let output: String
}

/// Runs a fixed tool with explicit arguments (never through a shell).
func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> ToolResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return ToolResult(status: -1, output: "\(error)") }
    var data = Data()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        return ToolResult(status: -1, output: "timeout")
    }
    process.waitUntilExit()
    return ToolResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

/// Name of the interface that carries the given IPv4 address (the utun that
/// charon creates for the virtual IP).
func interfaceName(forIPv4 address: String) -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let matched = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer -> Bool in
            var addr = pointer.pointee.sin_addr
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return false }
            return String(cString: buffer) == address
        }
        if matched { return String(cString: entry.pointee.ifa_name) }
    }
    return nil
}

struct RouteSpec: Codable, Equatable {
    /// CIDR, e.g. `10.0.0.0/8` or `192.168.0.155/32`.
    let destination: String
    let gateway: String?
    let interface: String?

    private var targetArguments: [String] {
        if destination.hasSuffix("/32") {
            return ["-host", String(destination.dropLast(3))]
        }
        return ["-net", destination]
    }

    private var viaArguments: [String] {
        if let gateway { return [gateway] }
        if let interface { return ["-interface", interface] }
        return []
    }

    func add() -> ToolResult {
        runTool("/sbin/route", ["-n", "add"] + targetArguments + viaArguments)
    }

    func delete() -> ToolResult {
        runTool("/sbin/route", ["-n", "delete"] + targetArguments + viaArguments)
    }
}

/// Where traffic to `address` currently goes, so a LAN exception can be pinned
/// before the broad VPN routes are installed.
func currentRoute(to address: String) -> (gateway: String?, interface: String?) {
    let result = runTool("/sbin/route", ["-n", "get", address])
    guard result.status == 0 else { return (nil, nil) }
    var gateway: String?, interface: String?
    for line in result.output.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { continue }
        if parts[0] == "gateway", parts[1].range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil { gateway = parts[1] }
        if parts[0] == "interface" { interface = parts[1] }
    }
    return (gateway, interface)
}

func networkAddress(of cidr: String) -> String {
    String(cidr.split(separator: "/")[0])
}
