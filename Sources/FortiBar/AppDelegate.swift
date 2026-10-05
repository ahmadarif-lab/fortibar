import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        let model = AppModel()
        self.model = model
        self.controller = StatusBarController(model: model)
        model.start()
        if Demo.isOn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if Demo.view == "settings" {
                    SettingsWindow.show(model: model)
                } else {
                    self?.controller?.openForDemo()
                }
            }
            return
        }
        LoginItem.enableOnFirstLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Accessory (menu bar) apps have no main menu, so the standard text
    /// shortcuts (select all, copy, paste, …) never reach text fields. Install
    /// an Edit menu; it stays invisible but its key equivalents work.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit FortiBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}
