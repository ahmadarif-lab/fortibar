import AppKit
import SwiftUI

/// Visual language for FortiBar. Kept in one place so the status item glyph,
/// the dropdown and the settings window stay in sync.
enum Theme {
    static let accent = Color(red: 0.25, green: 0.52, blue: 0.98)
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

extension View {
    func rowHoverBackground(_ isHovering: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
        )
    }

    /// Right-click "Copy" for text that may be longer than the panel shows.
    func copyableOnContextMenu(_ text: String) -> some View {
        contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

extension AppModel.Phase {
    var title: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .disconnected: return "Not connected"
        case .unknown: return "Checking…"
        case .error: return "Error"
        }
    }
}

extension AppModel.Phase {
    var symbolName: String {
        switch self {
        case .connected: return "shield.fill"
        case .connecting, .disconnecting: return "shield.lefthalf.filled"
        case .disconnected, .unknown: return "shield"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}
