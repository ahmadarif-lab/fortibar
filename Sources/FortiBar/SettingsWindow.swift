import AppKit
import SwiftUI

/// Settings in a real NSWindow: a menu bar app has no main window for a
/// SwiftUI `Settings` scene to hang off. FortiBar takes a Dock icon and a
/// Cmd-Tab entry only while this window is open, so it can be reached again
/// after switching to another app (e.g. to copy a credential).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static func show(model: AppModel) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "FortiBar Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ProfileEditorView(model: model))
            window.center()
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { close() }
            }
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func close() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window?.contentView = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
