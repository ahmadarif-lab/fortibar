import SwiftUI

/// Visual language for FortiBar. Kept in one place so the status item glyph and
/// the dropdown stay in sync.
enum Theme {
    static let accent = Color(red: 0.36, green: 0.62, blue: 0.98) // Forti-ish blue
    static let connected = Color(red: 0.20, green: 0.78, blue: 0.42)
    static let connecting = Color(red: 0.98, green: 0.68, blue: 0.20)
    static let disconnected = Color.secondary
    static let danger = Color(red: 0.93, green: 0.33, blue: 0.33)

    static let panelWidth: CGFloat = 320

    static func color(for state: AppModel.Phase) -> Color {
        switch state {
        case .connected: return connected
        case .connecting, .disconnecting: return connecting
        case .disconnected: return disconnected
        case .unknown, .error: return danger
        }
    }
}

extension AppModel.Phase {
    var title: String {
        switch self {
        case .connected: return "Terhubung"
        case .connecting: return "Menyambung…"
        case .disconnecting: return "Memutus…"
        case .disconnected: return "Terputus"
        case .unknown: return "Memeriksa…"
        case .error: return "Error"
        }
    }

    var symbolName: String {
        switch self {
        case .connected: return "shield.fill"
        case .connecting, .disconnecting: return "shield.lefthalf.filled"
        case .disconnected: return "shield"
        case .unknown: return "shield"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}
