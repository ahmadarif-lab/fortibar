import Foundation
import ServiceManagement

/// Start-at-login via SMAppService (macOS 13+), same approach as CSwapBar/StatBar.
enum LoginItem {
    private static let autoEnabledKey = "loginItemAutoEnabled"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Error? {
        // `swift run` has no .app bundle; registering would point at the build folder.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error
        }
    }

    /// Turn it on the first time the app ever runs, so a fresh install needs no
    /// follow-up step. If the user later switches it off, it stays off.
    static func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: autoEnabledKey) else { return }
        defaults.set(true, forKey: autoEnabledKey)
        setEnabled(true)
    }
}
