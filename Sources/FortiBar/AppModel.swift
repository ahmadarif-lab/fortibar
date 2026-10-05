import AppKit
import Foundation
import FortiBarCore
import SwiftUI
import UserNotifications

/// Single source of truth for the menu bar UI and the settings window.
///
/// FortiBar owns its profiles (gateway, username, PSK, password) and drives a
/// privileged helper that runs strongSwan. Only one tunnel can be up at a
/// time; the profile can only be changed while disconnected.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case unknown
        case disconnected
        case connecting
        case connected
        case disconnecting
        case error(String)
    }

    // MARK: - Published state

    @Published private(set) var phase: Phase = .unknown
    @Published private(set) var profiles: [NativeProfile] = []
    /// The profile chosen in the menu bar. Locked to the active profile while connected.
    @Published private(set) var selectedID: String?
    /// The profile the running tunnel belongs to.
    @Published private(set) var activeID: String?
    @Published private(set) var address: String?
    @Published private(set) var connectedSince: Date?
    @Published private(set) var busy = false
    @Published private(set) var events: [String] = []
    @Published private(set) var helperStatus: HelperStatus = .notInstalled
    @Published private(set) var helperBusy = false
    @Published private(set) var helperMessage: String?
    /// Profiles that have both PSK and password in the keychain.
    @Published private(set) var completeIDs: Set<String> = []

    /// FortiToken code for the next connection. Never stored.
    @Published var otp = ""

    @Published var launchAtLogin: Bool {
        didSet { LoginItem.setEnabled(launchAtLogin) }
    }

    // MARK: - Dependencies

    private let engine = NativeEngine()
    private let store = NativeProfileStore(path: Demo.isOn ? Demo.storeURL : nil)
    private var pollTimer: Timer?
    private var connectTask: Task<Void, Never>?
    private var lastState: VPNStatus.State = .unknown
    private var notifiedAuthorization = false

    private static let activeKey = "activeProfileID"
    private static let selectedKey = "selectedProfileID"

    // MARK: - Init

    init() {
        launchAtLogin = LoginItem.isEnabled
        profiles = store.items
        let saved = UserDefaults.standard.string(forKey: Self.selectedKey)
        selectedID = profiles.first { $0.id == saved }?.id ?? profiles.first?.id
        refreshCredentialState()
        if Demo.isOn { applyDemo() }
    }

    // MARK: - Derived

    var selectedProfile: NativeProfile? { profiles.first { $0.id == selectedID } }
    var activeProfile: NativeProfile? { profiles.first { $0.id == activeID } }
    var isConnected: Bool { phase == .connected }

    /// The selected profile is the one with the live tunnel.
    var selectedIsActive: Bool { isConnected && activeID == selectedID }

    var canConnect: Bool {
        guard !busy, let selected = selectedProfile else { return false }
        return helperStatus == .ready && completeIDs.contains(selected.id) && !selectedIsActive
    }

    var canDisconnect: Bool { !busy && isConnected }

    func isComplete(_ id: String) -> Bool { completeIDs.contains(id) }

    // MARK: - Lifecycle

    func start() {
        guard !Demo.isOn else { return }
        Task {
            await refreshHelperStatus()
            await refresh()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard !Demo.isOn else { return }
        await refreshHelperStatus()
        let engine = engine
        guard let status = try? await Task.detached(operation: { try engine.status() }).value, !busy else { return }
        apply(status)
    }

    // MARK: - Profiles

    func select(_ id: String) {
        guard !isConnected, id != selectedID, profiles.contains(where: { $0.id == id }) else { return }
        selectedID = id
        otp = ""
        UserDefaults.standard.set(id, forKey: Self.selectedKey)
        if phase.isError { phase = isConnected ? .connected : .disconnected }
    }

    func save(_ profile: NativeProfile) {
        do {
            try store.save(profile)
            profiles = store.items
            selectedID = profile.id
            UserDefaults.standard.set(profile.id, forKey: Self.selectedKey)
            refreshCredentialState()
            log("profile saved: \(profile.name)")
        } catch {
            phase = .error("Failed to save profile: \(error.localizedDescription)")
        }
    }

    func delete(id: String) {
        guard id != activeID else {
            phase = .error("Disconnect before deleting the active profile.")
            return
        }
        do {
            try store.delete(id: id)
            SecretStore.removeAll(profile: id)
            profiles = store.items
            if selectedID == id { selectedID = profiles.first?.id }
            refreshCredentialState()
            log("profile deleted")
        } catch {
            phase = .error("Failed to delete profile: \(error.localizedDescription)")
        }
    }

    // MARK: - Credentials

    func hasCredential(_ kind: SecretStore.SecretKind, profile id: String) -> Bool {
        if Demo.isOn { return true }
        return !SecretStore.get(profile: id, kind: kind).isEmpty
    }

    /// Empty values leave the stored one untouched.
    func updateCredentials(profile id: String, psk: String, password: String) {
        if !psk.isEmpty { SecretStore.set(psk, profile: id, kind: .psk) }
        if !password.isEmpty { SecretStore.set(password, profile: id, kind: .password) }
        refreshCredentialState()
        log("credentials updated")
    }

    func clearCredentials(profile id: String) {
        SecretStore.removeAll(profile: id)
        refreshCredentialState()
        log("stored credentials removed")
    }

    private func refreshCredentialState() {
        completeIDs = Set(profiles.map(\.id).filter {
            hasCredential(.psk, profile: $0) && hasCredential(.password, profile: $0)
        })
    }

    // MARK: - Connect / disconnect

    func connect() {
        guard !busy, !isConnected, let profile = selectedProfile else { return }
        let psk = SecretStore.get(profile: profile.id, kind: .psk)
        let password = SecretStore.get(profile: profile.id, kind: .password)
        guard !psk.isEmpty, !password.isEmpty else {
            phase = .error("Add the pre-shared key and password for \(profile.name) in Settings.")
            return
        }
        guard otp.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else {
            phase = .error("Enter the 6-digit FortiToken code.")
            return
        }
        let secrets = VPNSecrets(psk: psk, password: password, otp: otp)
        let engine = engine

        connectTask?.cancel()
        busy = true
        phase = .connecting
        notifyAuthorizationIfNeeded()
        log("connecting to \(profile.name)…")

        connectTask = Task { @MainActor in
            defer { busy = false; otp = "" }
            do {
                let status = try await Task.detached { try engine.up(profile: profile, secrets: secrets) }.value
                if status.state == .connected { setActive(profile.id) }
                apply(status)
                if status.state != .connected {
                    phase = .error("Unexpected status: \(status.state.rawValue)")
                }
            } catch {
                phase = .error(friendly(error))
                lastState = .disconnected
                setActive(nil)
                log("failed: \(friendly(error))")
            }
        }
    }

    func disconnect() {
        guard !busy else { return }
        let engine = engine
        connectTask?.cancel()
        busy = true
        phase = .disconnecting
        log("disconnecting…")
        Task { @MainActor in
            defer { busy = false }
            if let status = try? await Task.detached(operation: { try engine.down() }).value {
                apply(status)
            }
        }
    }

    func toggle() {
        selectedIsActive ? disconnect() : connect()
    }

    // MARK: - Helper

    func refreshHelperStatus() async {
        guard !Demo.isOn else { return }
        let engine = engine
        helperStatus = await Task.detached { engine.helperStatus() }.value
    }

    func installHelper() {
        guard !helperBusy else { return }
        helperBusy = true
        helperMessage = "Waiting for administrator approval…"
        Task { @MainActor in
            defer { helperBusy = false }
            do {
                try await Task.detached { try HelperInstaller.install() }.value
                // launchd needs a moment to start the daemon and create its socket.
                for _ in 0 ..< 20 {
                    await refreshHelperStatus()
                    if helperStatus != .notInstalled { break }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                helperMessage = helperStatus == .notInstalled
                    ? "Helper installed but not responding yet." : "Helper installed."
                log("helper installed")
            } catch {
                helperMessage = friendly(error)
                log("helper install failed: \(friendly(error))")
            }
        }
    }

    func uninstallHelper() {
        guard !helperBusy else { return }
        helperBusy = true
        helperMessage = "Waiting for administrator approval…"
        Task { @MainActor in
            defer { helperBusy = false }
            do {
                try await Task.detached { try HelperInstaller.uninstall() }.value
                await refreshHelperStatus()
                helperMessage = "Helper removed."
                log("helper removed")
            } catch {
                helperMessage = friendly(error)
            }
        }
    }

    // MARK: - State

    private func setActive(_ id: String?) {
        activeID = id
        if let id {
            UserDefaults.standard.set(id, forKey: Self.activeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeKey)
        }
    }

    private func apply(_ status: VPNStatus) {
        switch status.state {
        case .connected:
            if activeID == nil || !profiles.contains(where: { $0.id == activeID }) {
                // App restarted while the tunnel was up: recover the profile.
                let remembered = UserDefaults.standard.string(forKey: Self.activeKey)
                activeID = profiles.first { $0.id == remembered }?.id ?? selectedID
            }
            // The menu shows the live profile while connected.
            if let activeID, selectedID != activeID { selectedID = activeID }
            if lastState != .connected {
                connectedSince = Date()
                log("connected (\(status.address ?? "-"))")
                notify(title: "FortiBar", body: "Connected to \(activeProfile?.name ?? "VPN")"
                    + (status.address.map { " — \($0)" } ?? ""))
            }
            phase = .connected
        case .connecting:
            phase = .connecting
        case .disconnecting:
            phase = .disconnecting
        case .disconnected:
            if lastState == .connected {
                log("disconnected")
                notify(title: "FortiBar", body: "VPN disconnected")
            }
            connectedSince = nil
            setActive(nil)
            if !phase.isError || lastState == .connected { phase = .disconnected }
        case .unknown:
            break
        }
        lastState = status.state
        address = status.address
    }

    private func friendly(_ error: Error) -> String {
        if let e = error as? VPNError { return e.message }
        return error.localizedDescription
    }

    func log(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        events.insert("[\(stamp)] \(line)", at: 0)
        if events.count > 60 { events.removeLast(events.count - 60) }
    }

    // MARK: - Notifications

    private func notifyAuthorizationIfNeeded() {
        guard !notifiedAuthorization else { return }
        notifiedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Display

    var uptimeText: String? {
        guard let since = connectedSince else { return nil }
        let seconds = Int(Date().timeIntervalSince(since))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}

extension AppModel.Phase {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

// MARK: - Screenshot mode

/// `FORTIBAR_DEMO=disconnected|connected` runs the app on made-up profiles with no
/// helper, keychain or saved data involved, so README screenshots never show
/// real gateways or accounts. `FORTIBAR_DEMO_VIEW=panel|settings` picks what opens.
enum Demo {
    static let mode = ProcessInfo.processInfo.environment["FORTIBAR_DEMO"]
    static var isOn: Bool { mode != nil }
    static var view: String { ProcessInfo.processInfo.environment["FORTIBAR_DEMO_VIEW"] ?? "panel" }
    static var storeURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fortibar-demo/profiles.json")
    }
}

extension AppModel {
    fileprivate func applyDemo() {
        profiles = [
            NativeProfile(name: "Office", gateway: "vpn.example.com", peerID: "", username: "jdoe"),
            NativeProfile(name: "Lab", gateway: "lab-vpn.example.com", peerID: "", username: "jdoe"),
        ]
        selectedID = profiles.first?.id
        helperStatus = .ready
        completeIDs = Set(profiles.map(\.id))
        if Demo.mode == "connected" {
            activeID = selectedID
            phase = .connected
            address = "10.3.3.9"
            connectedSince = Date().addingTimeInterval(-754)
            log("connected (10.3.3.9)")
            log("connecting to Office…")
        } else {
            phase = .disconnected
            otp = "492817"
        }
    }
}
