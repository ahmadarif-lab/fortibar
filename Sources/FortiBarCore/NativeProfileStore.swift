import Foundation

/// Persists FortiBar-owned native profiles as plain JSON. Secrets never land
/// here; see `SecretStore`.
public final class NativeProfileStore: @unchecked Sendable {
    public private(set) var items: [NativeProfile] = []

    public let path: URL

    public init(path: URL? = nil) {
        self.path = path ?? Self.defaultPath
        load()
    }

    public static var defaultPath: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FortiBar/native-profiles.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: path),
              let list = try? JSONDecoder().decode([NativeProfile].self, from: data)
        else { return }
        items = list
    }

    public func save(_ profile: NativeProfile) throws {
        var updated = items.filter { $0.id != profile.id }
        updated.append(profile)
        try write(updated)
    }

    public func delete(id: String) throws {
        try write(items.filter { $0.id != id })
    }

    public func profile(id: String) -> NativeProfile? {
        items.first { $0.id == id }
    }

    private func write(_ list: [NativeProfile]) throws {
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(list)
        try data.write(to: path, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        items = list
    }
}
