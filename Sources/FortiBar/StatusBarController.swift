import AppKit
import Combine
import FortiBarCore
import SwiftUI

/// The menu bar item plus its dropdown panel.
@MainActor
final class StatusBarController: NSObject {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private var panel: DropdownPanel?
    private var hosting: NSHostingView<DropdownView>?
    private var subscriptions: Set<AnyCancellable> = []
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var outsideClickMonitor: Any?
    /// When the open panel last closed. A click on the status item already
    /// closes the panel (as an outside click, or by taking its focus) before
    /// the click itself arrives; without this, clicking the item would reopen
    /// it instead of toggling it shut.
    private var lastDismissal: Date?

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        model.objectWillChange
            .debounce(for: .milliseconds(25), scheduler: RunLoop.main)
            .sink { [weak self] in self?.render() }
            .store(in: &subscriptions)

        render()
    }

    // MARK: - Status item

    private func render() {
        guard let button = statusItem.button else { return }
        let phase = model.phase

        button.image = Self.shieldImage(filled: phase == .connected, tint: Self.tint(for: phase))
        button.contentTintColor = nil
        button.toolTip = "FortiBar — \(phase.title)"

        if phase == .connecting || phase == .disconnecting {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    /// Colour for the drawn glyph. The status item renders the image with its
    /// own colours (the template flag is not honoured here), so the adaptive
    /// case has to be resolved by hand against the current appearance.
    private static func tint(for phase: AppModel.Phase) -> NSColor {
        switch phase {
        case .connected:
            return NSColor(Theme.connected)
        case .connecting, .disconnecting:
            return NSColor(Theme.connecting)
        case .error:
            return NSColor(Theme.danger)
        case .disconnected, .unknown:
            return adaptiveColor()
        }
    }

    private static func adaptiveColor() -> NSColor {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .white : .black
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.statusItem.button else { return }
                self.animationFrame = (self.animationFrame + 1) % 2
                button.image = StatusBarController.shieldImage(
                    filled: self.animationFrame == 1,
                    tint: StatusBarController.tint(for: self.model.phase))
            }
        }
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    /// A hand-drawn shield. SF Symbols inside an NSStatusItem button render
    /// solid black on a dark menu bar, and the template flag is not honoured,
    /// so the glyph is drawn with an explicit colour instead.
    private static func shieldImage(filled: Bool, tint: NSColor, size: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let w = rect.width
            let h = rect.height
            let path = NSBezierPath()
            path.move(to: NSPoint(x: w * 0.50, y: h * 0.96))
            path.line(to: NSPoint(x: w * 0.90, y: h * 0.78))
            path.line(to: NSPoint(x: w * 0.90, y: h * 0.44))
            path.curve(
                to: NSPoint(x: w * 0.50, y: h * 0.05),
                controlPoint1: NSPoint(x: w * 0.90, y: h * 0.22),
                controlPoint2: NSPoint(x: w * 0.74, y: h * 0.10))
            path.curve(
                to: NSPoint(x: w * 0.10, y: h * 0.44),
                controlPoint1: NSPoint(x: w * 0.26, y: h * 0.10),
                controlPoint2: NSPoint(x: w * 0.10, y: h * 0.22))
            path.line(to: NSPoint(x: w * 0.10, y: h * 0.78))
            path.close()

            if filled {
                tint.setFill()
                path.fill()
            } else {
                path.lineWidth = 1.7
                path.lineJoinStyle = .round
                tint.setStroke()
                path.stroke()
            }
            return true
        }
        return image
    }

    // MARK: - Panel

    @objc private func handleClick() {
        if panel != nil {
            close()
            return
        }
        // Ignore the mouse-up that follows the outside click which just
        // dismissed the panel, so the item toggles shut instead of reopening.
        if let lastDismissal, Date().timeIntervalSince(lastDismissal) < 0.3 {
            return
        }
        open()
    }

    private func open() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.onResignKey = { [weak self] in self?.close() }
        panel.onEscape = { [weak self] in self?.close() }

        let size = hosting?.fittingSize ?? NSSize(width: Theme.panelWidth, height: 360)
        panel.setContentSize(NSSize(width: Theme.panelWidth, height: size.height))

        if let button = statusItem.button, let window = button.window {
            let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            let origin = NSPoint(
                x: buttonFrame.midX - Theme.panelWidth / 2,
                y: buttonFrame.minY - panel.frame.height - 6
            )
            panel.setFrameOrigin(origin)
        }

        panel.makeKeyAndOrderFront(nil)
        // Clicks on other apps or the desktop never reach the panel, so close
        // on any mouse-down outside it too.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        Task { await model.refresh() }
    }

    private func makePanel() -> DropdownPanel {
        let panel = DropdownPanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 360),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let view = DropdownView(model: model, onClose: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 360)
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }

    private func close() {
        if panel != nil { lastDismissal = Date() }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        panel?.onResignKey = nil
        panel?.onEscape = nil
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }
}

/// Borderless panel that can take key status without activating FortiBar, so
/// clicking outside (or pressing Escape) dismisses the dropdown while the app
/// in front keeps its focus.
final class DropdownPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
