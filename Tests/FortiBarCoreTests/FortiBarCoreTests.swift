import XCTest
@testable import FortiBarCore

final class ViciTests: XCTestCase {
    func testKnownWireVector() throws {
        // Example from the strongSwan VICI documentation shape:
        // section "a" { key = "v"; list "l" { "x" } }
        var inner = ViciMessage()
        inner.set("key", "v")
        inner.set("l", list: ["x"])
        var message = ViciMessage()
        message.set("a", section: inner)
        let bytes = message.encoded()
        let expected: [UInt8] = [1, 1, 0x61,
                                 3, 3, 0x6b, 0x65, 0x79, 0, 1, 0x76,
                                 4, 1, 0x6c, 5, 0, 1, 0x78, 6,
                                 2]
        XCTAssertEqual(bytes, expected)
        XCTAssertEqual(try ViciMessage.decode(bytes), message)
    }

    func testRoundTripOfConnection() throws {
        let params = ConnectParams(profile: sampleProfile(), secrets: VPNSecrets(psk: "k", password: "p", otp: "123456"))
        let message = ViciConfig.connection(params)
        XCTAssertEqual(try ViciMessage.decode(message.encoded()), message)
        let conn = try XCTUnwrap(message.section("fortibar"))
        XCTAssertEqual(conn.string("aggressive"), "yes")
        XCTAssertEqual(conn.string("keyingtries"), "1")
        XCTAssertEqual(conn.list("remote_addrs"), ["203.0.113.10"])
        // Empty peer ID must not pin the remote identity.
        XCTAssertNil(conn.section("remote")?.string("id"))
    }

    func testDecodeRejectsTruncatedAndUnbalanced() {
        XCTAssertThrowsError(try ViciMessage.decode([3, 5, 0x61]))
        XCTAssertThrowsError(try ViciMessage.decode([2]))
        XCTAssertThrowsError(try ViciMessage.decode([1, 1, 0x61]))
    }

    func testSecretsMayContainAnyCharacters() throws {
        var message = ViciMessage()
        message.set("data", "a\"b\\c#d é")
        XCTAssertEqual(try ViciMessage.decode(message.encoded()).string("data"), "a\"b\\c#d é")
    }
}

final class ValidationTests: XCTestCase {
    func params(_ edit: (inout ConnectParams) -> Void = { _ in }) -> ConnectParams {
        var p = ConnectParams(profile: sampleProfile(), secrets: VPNSecrets(psk: "psk-value", password: "secret1", otp: "123456"))
        edit(&p)
        return p
    }

    func testValidParamsPass() {
        XCTAssertNoThrow(try HelperValidation.validate(params()))
    }

    func testRejectsBadInput() {
        let bad: [(inout ConnectParams) -> Void] = [
            { $0.gateway = "1.2.3.4; rm -rf /" },
            { $0.username = "a b" },
            { $0.otp = "12345" },
            { $0.otp = "12345a" },
            { $0.psk = "" },
            { $0.password = "x\ny" },
            { $0.ike = "aes128-sha1-modp1536,evil" },
            { $0.routes = [] },
            { $0.routes = ["0.0.0.0/0"] },
            { $0.routes = ["10.0.0.0/33"] },
            { $0.routes = ["10.0.0.0/8; reboot"] },
            { $0.lanExceptions = ["300.1.1.1/32"] },
            { $0.peerID = "bad id" },
        ]
        for edit in bad {
            XCTAssertThrowsError(try HelperValidation.validate(params(edit)))
        }
    }

    func testCIDR() {
        XCTAssertTrue(HelperValidation.isIPv4CIDR("172.16.0.0/12"))
        XCTAssertFalse(HelperValidation.isIPv4CIDR("172.16.0.0"))
        XCTAssertFalse(HelperValidation.isIPv4CIDR("01.2.3.4/8"))
    }
}

func sampleProfile() -> NativeProfile {
    NativeProfile(name: "Test", gateway: "203.0.113.10", peerID: "", username: "jdoe")
}
