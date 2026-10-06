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

final class BrewUpgradeTests: XCTestCase {
    func testSummarizePrefersBrewsErrorLine() {
        let output = """
        ==> Upgrading 1 outdated package:
        ==> Downloading https://example.invalid/FortiBar.dmg
        Error: Download failed on Cask 'fortibar'
        Please try again later.
        """
        XCTAssertEqual(BrewUpgrade.summarize(output), "Error: Download failed on Cask 'fortibar'")
    }

    func testSummarizeFallsBackToLastLine() {
        XCTAssertEqual(BrewUpgrade.summarize("first\n\nlast line  \n\n"), "last line")
        XCTAssertFalse(BrewUpgrade.summarize("").isEmpty)
    }

    func testDetectsHomebrewInstallByCaskroomEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let caskroom = root.appendingPathComponent("Caskroom/fortibar")
        XCTAssertFalse(BrewUpgrade.installedViaHomebrew(caskrooms: [caskroom.path]))
        try FileManager.default.createDirectory(at: caskroom, withIntermediateDirectories: true)
        XCTAssertTrue(BrewUpgrade.installedViaHomebrew(caskrooms: [caskroom.path]))
        XCTAssertTrue(BrewUpgrade.installedViaHomebrew(caskrooms: ["/nonexistent/one", caskroom.path]))
    }

    func testFindsBrewOnlyWhenExecutable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let brew = dir.appendingPathComponent("brew")
        FileManager.default.createFile(atPath: brew.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o644])
        XCTAssertNil(BrewUpgrade.brewPath(candidates: [brew.path]))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        XCTAssertEqual(BrewUpgrade.brewPath(candidates: ["/nonexistent/brew", brew.path]), brew.path)
    }
}

final class RouteVIPLocallyTests: XCTestCase {
    func testDefaultsToOff() {
        XCTAssertFalse(sampleProfile().routeVIPLocally)
        XCTAssertFalse(NativeProfile.fresh().routeVIPLocally)
    }

    func testProfileFromEarlierVersionStillDecodes() throws {
        let old = """
        [{"id":"1","name":"Old","gateway":"203.0.113.10","peerID":"","username":"jdoe",
          "routes":["10.0.0.0/8"],"lanExceptions":[],"ike":"aes128-sha1-modp1536","esp":"aes128-sha1"}]
        """
        let list = try JSONDecoder().decode([NativeProfile].self, from: Data(old.utf8))
        XCTAssertEqual(list.count, 1)
        XCTAssertFalse(list[0].routeVIPLocally)
    }

    func testProfileRoundTripKeepsSetting() throws {
        var profile = sampleProfile()
        profile.routeVIPLocally = true
        let data = try JSONEncoder().encode([profile])
        let back = try JSONDecoder().decode([NativeProfile].self, from: data)
        XCTAssertTrue(back[0].routeVIPLocally)
    }

    func testConnectParamsCarrySetting() throws {
        var profile = sampleProfile()
        profile.routeVIPLocally = true
        let params = ConnectParams(profile: profile, secrets: VPNSecrets(psk: "k", password: "p", otp: "123456"))
        XCTAssertTrue(params.routeVIPLocally)
        let back = try JSONDecoder().decode(ConnectParams.self, from: JSONEncoder().encode(params))
        XCTAssertTrue(back.routeVIPLocally)
    }

    func testConnectParamsFromEarlierAppStillDecode() throws {
        var profile = sampleProfile()
        profile.routeVIPLocally = true
        let params = ConnectParams(profile: profile, secrets: VPNSecrets(psk: "k", password: "p", otp: "123456"))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as! [String: Any]
        object.removeValue(forKey: "routeVIPLocally")
        let data = try JSONSerialization.data(withJSONObject: object)
        let back = try JSONDecoder().decode(ConnectParams.self, from: data)
        XCTAssertFalse(back.routeVIPLocally)
    }
}

func sampleProfile() -> NativeProfile {
    NativeProfile(name: "Test", gateway: "203.0.113.10", peerID: "", username: "jdoe")
}

final class UpdateCheckerTests: XCTestCase {
    func testVersionOrdering() throws {
        let v = { try XCTUnwrap(AppVersion($0)) }
        XCTAssertLessThan(try v("0.1.0"), try v("0.2.0"))
        XCTAssertLessThan(try v("0.9.9"), try v("0.10.0"))
        XCTAssertLessThan(try v("1.0"), try v("1.0.1"))
        XCTAssertEqual(try v("v1.2"), try v("1.2.0"))
        XCTAssertEqual(try v("1.2.0-beta.1"), try v("1.2.0"))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion(""))
    }

    func testParseRelease() throws {
        let json = #"{"tag_name":"v0.2.0","html_url":"https://github.com/ahmadarif-lab/fortibar/releases/tag/v0.2.0","draft":false,"prerelease":false}"#
        let release = try UpdateChecker.parse(Data(json.utf8))
        XCTAssertEqual(release.version, "0.2.0")
    }

    func testParseRejectsPrereleaseAndForeignURL() {
        let pre = #"{"tag_name":"v0.2.0","html_url":"https://github.com/x/y","prerelease":true}"#
        XCTAssertThrowsError(try UpdateChecker.parse(Data(pre.utf8)))
        let foreign = #"{"tag_name":"v0.2.0","html_url":"https://evil.example/x"}"#
        XCTAssertThrowsError(try UpdateChecker.parse(Data(foreign.utf8)))
        let badTag = #"{"tag_name":"nightly","html_url":"https://github.com/x/y"}"#
        XCTAssertThrowsError(try UpdateChecker.parse(Data(badTag.utf8)))
    }
}
