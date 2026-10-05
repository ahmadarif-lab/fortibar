import Foundation
import Security

/// Keychain storage for native-profile secrets (PSK, password). Never for OTP.
public enum SecretStore {
    public enum SecretKind: String, CaseIterable, Sendable {
        case psk
        case password
    }

    private static let service = "io.github.fortibar"

    private static func account(profile: String, kind: SecretKind) -> String {
        "\(profile):\(kind.rawValue)"
    }

    private static func query(profile: String, kind: SecretKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(profile: profile, kind: kind),
        ]
    }

    @discardableResult
    public static func set(_ value: String, profile: String, kind: SecretKind) -> Bool {
        guard !value.isEmpty else {
            remove(profile: profile, kind: kind)
            return true
        }
        var attributes = query(profile: profile, kind: kind)
        SecItemDelete(attributes as CFDictionary)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func get(profile: String, kind: SecretKind) -> String {
        var attributes = query(profile: profile, kind: kind)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return "" }
        return value
    }

    @discardableResult
    public static func remove(profile: String, kind: SecretKind) -> Bool {
        let status = SecItemDelete(query(profile: profile, kind: kind) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public static func removeAll(profile: String) {
        for kind in SecretKind.allCases { remove(profile: profile, kind: kind) }
    }
}
