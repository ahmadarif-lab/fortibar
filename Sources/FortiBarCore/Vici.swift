import Darwin
import Foundation

/// A VICI message: ordered key/values, lists and nested sections.
///
/// VICI is strongSwan's control protocol (the same one the Linux `vpn-desk`
/// app speaks through its vendored Python binding). Loading connections and
/// secrets over VICI means nothing is written to `swanctl.conf`/`ipsec.secrets`
/// and secrets can be dropped from the daemon right after the handshake.
public struct ViciMessage: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        case value(String, String)
        case list(String, [String])
        case section(String, ViciMessage)
    }

    public var items: [Item]

    public init(_ items: [Item] = []) {
        self.items = items
    }

    // MARK: Builders

    public mutating func set(_ key: String, _ value: String) { items.append(.value(key, value)) }
    public mutating func set(_ key: String, list: [String]) { items.append(.list(key, list)) }
    public mutating func set(_ key: String, section: ViciMessage) { items.append(.section(key, section)) }

    // MARK: Accessors

    public func string(_ key: String) -> String? {
        for case .value(let name, let value) in items where name == key { return value }
        return nil
    }

    public func list(_ key: String) -> [String] {
        for case .list(let name, let values) in items where name == key { return values }
        return []
    }

    public func section(_ key: String) -> ViciMessage? {
        for case .section(let name, let message) in items where name == key { return message }
        return nil
    }

    public var sections: [(name: String, message: ViciMessage)] {
        items.compactMap { if case .section(let name, let message) = $0 { return (name, message) } else { return nil } }
    }

    // MARK: Wire format

    private enum Element: UInt8 {
        case sectionStart = 1, sectionEnd, keyValue, listStart, listItem, listEnd
    }

    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        for item in items {
            switch item {
            case .value(let key, let value):
                out.append(Element.keyValue.rawValue)
                Self.appendName(key, to: &out)
                Self.appendValue(value, to: &out)
            case .list(let key, let values):
                out.append(Element.listStart.rawValue)
                Self.appendName(key, to: &out)
                for value in values {
                    out.append(Element.listItem.rawValue)
                    Self.appendValue(value, to: &out)
                }
                out.append(Element.listEnd.rawValue)
            case .section(let key, let message):
                out.append(Element.sectionStart.rawValue)
                Self.appendName(key, to: &out)
                out += message.encoded()
                out.append(Element.sectionEnd.rawValue)
            }
        }
        return out
    }

    private static func appendName(_ name: String, to out: inout [UInt8]) {
        let bytes = Array(name.utf8.prefix(255))
        out.append(UInt8(bytes.count))
        out += bytes
    }

    private static func appendValue(_ value: String, to out: inout [UInt8]) {
        let bytes = Array(value.utf8.prefix(Int(UInt16.max)))
        out.append(UInt8(bytes.count >> 8))
        out.append(UInt8(bytes.count & 0xff))
        out += bytes
    }

    public struct DecodeError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func decode(_ bytes: [UInt8]) throws -> ViciMessage {
        var position = 0
        let message = try parse(bytes, &position, nested: false)
        return message
    }

    private static func parse(_ bytes: [UInt8], _ pos: inout Int, nested: Bool) throws -> ViciMessage {
        var message = ViciMessage()
        func byte() throws -> UInt8 {
            guard pos < bytes.count else { throw DecodeError(description: "truncated VICI message") }
            defer { pos += 1 }
            return bytes[pos]
        }
        func take(_ count: Int) throws -> String {
            guard pos + count <= bytes.count else { throw DecodeError(description: "truncated VICI message") }
            defer { pos += count }
            return String(decoding: bytes[pos ..< pos + count], as: UTF8.self)
        }
        func name() throws -> String { try take(Int(try byte())) }
        func value() throws -> String {
            let high = Int(try byte()), low = Int(try byte())
            return try take(high << 8 | low)
        }

        while pos < bytes.count {
            guard let element = Element(rawValue: try byte()) else {
                throw DecodeError(description: "unknown VICI element")
            }
            switch element {
            case .sectionStart:
                let key = try name()
                message.items.append(.section(key, try parse(bytes, &pos, nested: true)))
            case .sectionEnd:
                guard nested else { throw DecodeError(description: "unbalanced SECTION_END") }
                return message
            case .keyValue:
                let key = try name()
                message.items.append(.value(key, try value()))
            case .listStart:
                let key = try name()
                var values: [String] = []
                listLoop: while true {
                    guard let inner = Element(rawValue: try byte()) else {
                        throw DecodeError(description: "unknown list element")
                    }
                    switch inner {
                    case .listItem: values.append(try value())
                    case .listEnd: break listLoop
                    default: throw DecodeError(description: "unexpected element in list")
                    }
                }
                message.items.append(.list(key, values))
            case .listItem, .listEnd:
                throw DecodeError(description: "list element outside a list")
            }
        }
        if nested { throw DecodeError(description: "unterminated section") }
        return message
    }
}

/// Minimal blocking Unix-domain socket helpers shared by the VICI client and
/// the app <-> helper channel.
public enum UnixSocket {
    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ViciError("socket() failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw ViciError("socket path too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { pointer in
                for (index, byte) in bytes.enumerated() { pointer[index] = byte }
                pointer[bytes.count] = 0
            }
        }
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw ViciError("cannot connect (\(reason))")
        }
        return fd
    }

    public static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    /// Reads up to and excluding the first newline. Nil on EOF/timeout/overflow.
    public static func readLine(_ fd: Int32, limit: Int = 128 * 1024) -> [UInt8]? {
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while line.count < limit {
            let count = read(fd, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { return line.isEmpty ? nil : line }
            if byte == 10 { return line }
            line.append(byte)
        }
        return nil
    }
}

public struct ViciError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Synchronous VICI client over a Unix socket. Not thread-safe: use one
/// instance per operation.
public final class ViciClient {
    private enum Packet: UInt8 {
        case request = 0, response, unknownCommand, register, unregister, confirm, unknownEvent, event
    }

    private var fd: Int32

    /// - Parameter timeout: per-read timeout in seconds.
    public init(path: String, timeout: TimeInterval = 15) throws {
        fd = try UnixSocket.connect(path: path)
        setTimeout(timeout)
    }

    deinit { close(fd) }

    public func setTimeout(_ seconds: TimeInterval) { UnixSocket.setTimeout(fd, seconds) }

    /// Plain request/response command.
    @discardableResult
    public func request(_ command: String, _ message: ViciMessage = ViciMessage()) throws -> ViciMessage {
        try stream(command, message, events: []) { _, _ in }
    }

    /// Request that also collects named events (e.g. `control-log`, `list-sa`)
    /// until the command response arrives.
    @discardableResult
    public func stream(
        _ command: String,
        _ message: ViciMessage,
        events: [String],
        onEvent: (String, ViciMessage) -> Void
    ) throws -> ViciMessage {
        for event in events {
            try send(.register, name: event, message: nil)
            let (type, _, _) = try receive()
            guard type == .confirm else { throw ViciError("charon rejected event \(event)") }
        }
        try send(.request, name: command, message: message)
        var response: ViciMessage?
        while response == nil {
            let (type, name, body) = try receive()
            switch type {
            case .event: onEvent(name, body)
            case .response: response = body
            case .unknownCommand: throw ViciError("unknown VICI command: \(command)")
            default: continue
            }
        }
        for event in events {
            try send(.unregister, name: event, message: nil)
            _ = try? receive()
        }
        return response ?? ViciMessage()
    }

    /// `request` that also requires `success = yes` in the response.
    @discardableResult
    public func command(_ name: String, _ message: ViciMessage = ViciMessage()) throws -> ViciMessage {
        let response = try request(name, message)
        if let success = response.string("success"), success != "yes" {
            throw ViciError(response.string("errmsg") ?? "\(name) failed")
        }
        return response
    }

    // MARK: Framing

    private func send(_ type: Packet, name: String, message: ViciMessage?) throws {
        var payload: [UInt8] = [type.rawValue]
        let nameBytes = Array(name.utf8)
        payload.append(UInt8(nameBytes.count))
        payload += nameBytes
        if let message { payload += message.encoded() }
        var frame: [UInt8] = []
        let length = UInt32(payload.count)
        frame += [UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)]
        frame += payload
        guard UnixSocket.writeAll(fd, frame) else { throw ViciError("failed to write to charon") }
    }

    private func readExactly(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            if received == 0 { throw ViciError("charon closed the connection") }
            if received < 0 {
                if errno == EINTR { continue }
                throw ViciError(errno == EAGAIN ? "charon did not respond (timeout)" : "failed to read from charon")
            }
            offset += received
        }
        return buffer
    }

    private func receive() throws -> (Packet, String, ViciMessage) {
        let header = try readExactly(4)
        let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        guard length > 0, length < 16 * 1024 * 1024 else { throw ViciError("invalid VICI packet") }
        let payload = try readExactly(length)
        guard let type = Packet(rawValue: payload[0]) else { throw ViciError("unknown VICI packet type") }
        switch type {
        case .event:
            guard payload.count > 1 else { throw ViciError("empty VICI event") }
            let nameLength = Int(payload[1])
            guard payload.count >= 2 + nameLength else { throw ViciError("truncated VICI event") }
            let name = String(decoding: payload[2 ..< 2 + nameLength], as: UTF8.self)
            let body = try ViciMessage.decode(Array(payload[(2 + nameLength)...]))
            return (type, name, body)
        case .response:
            return (type, "", try ViciMessage.decode(Array(payload.dropFirst())))
        default:
            return (type, "", ViciMessage())
        }
    }
}
