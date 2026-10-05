import Foundation

/// A dotted version such as `0.2.1`. A leading `v` and anything after a `-` or
/// `+` (pre-release / build tags) are ignored; missing components count as 0.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
        if let cut = body.firstIndex(where: { $0 == "-" || $0 == "+" }) { body = String(body[..<cut]) }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        components = parts.compactMap { $0 }
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0 ..< max(lhs.components.count, rhs.components.count) {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// A published GitHub release.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: String
    public let url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// Looks up the latest GitHub release and compares it with the running version.
public enum UpdateChecker {
    public static let repository = "ahmadarif-lab/fortibar"
    public static let upgradeCommand = "brew upgrade --cask fortibar"

    static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// Parses the `releases/latest` payload. Drafts and pre-releases never count.
    static func parse(_ data: Data) throws -> ReleaseInfo {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.draft != true, payload.prerelease != true, let version = AppVersion(payload.tag_name) else {
            throw VPNError(message: "No usable release found.")
        }
        // Only ever link to the repository's own pages.
        guard payload.html_url.scheme == "https", payload.html_url.host == "github.com" else {
            throw VPNError(message: "Unexpected release URL.")
        }
        return ReleaseInfo(version: version.description, url: payload.html_url)
    }

    /// The latest release when it is newer than `current`, otherwise nil.
    public static func check(current: String) async throws -> ReleaseInfo? {
        guard let running = AppVersion(current) else { return nil }
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FortiBar/\(running)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VPNError(message: "GitHub returned an unexpected response.")
        }
        let release = try parse(data)
        guard let latest = AppVersion(release.version), latest > running else { return nil }
        return release
    }
}
