import AppKit
import Foundation
import FortiBarCore
import UserNotifications

/// Single source of truth for the menu bar UI: talks to the `fortivpn` CLI,
/// tracks connection state, and drives auto-reconnect.
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

    @Published private(set) var phase: Phase = .unknown
    @Published private(set) var profiles: [VPNProfile] = []
    @Published private(set) var selectedProfile: VPNProfile?
    @Published private(set) var address: String?
    @Published private(set) var connectedSince: Date?
    @Published private(set) var doctorChecks: [DoctorCheck] = []
    @Published private(set) var busy = false
    @Published private(set) var events: [String] = []
    @Published var autoReconnect: Bool {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") }
    }
    @Published var launchAtLogin: Bool {
        didSet { LoginItem.setEnabled(launchAtLogin) }
    }

    private let client: FortiVPNClient?
    private var pollTimer: Timer?
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var userInitiatedDisconnect = false
    private var lastState: VPNStatus.State = .unknown
    private var notifiedAuthorization = false

    var isConnected: Bool { phase == .connected }
    var canConnect: Bool { client != nil && selectedProfile != nil && !busy && !isConnected }
    var canDisconnect: Bool { client != nil && !busy && isConnected }
    var hasWarnings: Bool { doctorChecks.contains(where: \.isWarning) }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "autoReconnect") == nil {
            defaults.set(true, forKey: "autoReconnect")
        }
        autoReconnect = defaults.bool(forKey: "autoReconnect")
        launchAtLogin = LoginItem.isEnabled
        client = FortiVPNClient.locate()
        if client == nil {
            phase = .error("CLI fortivpn tidak ditemukan")
            log("CLI fortivpn tidak ditemukan")
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard client != nil else { return }
        Task { await loadProfiles() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    // MARK: - Actions

    func loadProfiles() async {
        guard let client else { return }
        do {
            let list = try await Task.detached { try client.profiles() }.value
            profiles = list
            if selectedProfile == nil {
                selectedProfile = list.first
            }
            log("profile dimuat: \(list.map(\.name).joined(separator: ", "))")
            await refresh()
            await runDoctor()
        } catch {
            phase = .error(friendly(error))
        }
    }

    func selectProfile(_ profile: VPNProfile) {
        selectedProfile = profile
    }

    func refresh() async {
        guard let client else { return }
        let name = selectedProfile?.name
        do {
            let status = try await Task.detached { try client.status(profile: name) }.value
            apply(status)
        } catch {
            // Transient failures are normal while connecting; keep the last state.
        }
    }

    func connect() {
        guard let client, let profile = selectedProfile, !busy else { return }
        connectTask?.cancel()
        reconnectTask?.cancel()
        userInitiatedDisconnect = false
        busy = true
        phase = .connecting
        log("menyambung ke \(profile.name)…")
        notifyAuthorizationIfNeeded()

        connectTask = Task { @MainActor in
            defer { busy = false }
            do {
                let status = try await Task.detached {
                    try client.up(profile: profile.name, timeout: 120)
                }.value
                apply(status)
            } catch {
                phase = .error(friendly(error))
                lastState = .disconnected
                log("gagal: \(friendly(error))")
            }
        }
    }

    func disconnect() {
        guard let client, let profile = selectedProfile else { return }
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        connectTask?.cancel()
        busy = true
        phase = .disconnecting
        log("memutus \(profile.name)…")
        Task { @MainActor in
            defer { busy = false }
            _ = try? await Task.detached { try client.down(profile: profile.name) }.value
            await refresh()
        }
    }

    func toggle() {
        isConnected ? disconnect() : connect()
    }

    func runDoctor() async {
        guard let client else { return }
        let checks: [DoctorCheck]? = try? await Task.detached(operation: { try client.doctor() }).value
        guard let checks else { return }
        // The bundled CLI emits its own (Chinese) messages and warns about its
        // own default-profile setting, which FortiBar never uses because it
        // always passes --profile. Show our own text, keep only real problems.
        doctorChecks = checks.compactMap { check -> DoctorCheck? in
            guard check.isWarning, let message = Self.warningText(for: check.name) else { return nil }
            return DoctorCheck(name: check.name, status: check.status, message: message)
        }
    }

    private static func warningText(for checkName: String) -> String? {
        switch checkName {
        case "forticlient":
            return "FortiClient bermasalah — cek instalasinya di /Applications."
        case "profiles":
            return "Tidak ada profil VPN di FortiClient. Buat profilnya dulu."
        case "fortitray-ipc":
            return "Kontrol FortiTray tidak tersedia — buka FortiClient sekali, lalu Refresh."
        default:
            // Includes the CLI's own "default-profile" note: not relevant here.
            return nil
        }
    }

    /// Opens the FortiClient window — needed when FortiTray asks for a
    /// FortiToken code or a SAML/browser round-trip.
    func openFortiClient() {
        let app = URL(fileURLWithPath: "/Applications/FortiClient.app")
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - State plumbing

    private func apply(_ status: VPNStatus) {
        let new = status.parsedState
        switch new {
        case .connected:
            if lastState != .connected {
                connectedSince = Date()
                log("terhubung (\(status.primaryAddress ?? "-"))")
                notify(title: "FortiBar", body: "VPN tersambung" + (status.primaryAddress.map { " — \($0)" } ?? ""))
            }
            phase = .connected
        case .connecting:
            phase = .connecting
        case .disconnecting:
            phase = .disconnecting
        case .disconnected:
            if lastState == .connected {
                connectedSince = nil
                log("terputus")
                notify(title: "FortiBar", body: "VPN terputus")
                scheduleAutoReconnectIfWanted()
            } else if lastState == .unknown {
                phase = .disconnected
            } else {
                phase = .disconnected
            }
        case .unknown:
            break
        }
        lastState = new
        address = status.primaryAddress
        if let name = status.profile, let match = profiles.first(where: { $0.name == name }) {
            selectedProfile = match
        }
    }

    private func scheduleAutoReconnectIfWanted() {
        guard autoReconnect, !userInitiatedDisconnect, selectedProfile != nil else { return }
        reconnectTask?.cancel()
        log("auto-reconnect dalam 5 detik…")
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            guard !isConnected, !userInitiatedDisconnect else { return }
            connect()
        }
    }

    private func friendly(_ error: Error) -> String {
        if let e = error as? FortiVPNError { return e.message }
        return String(describing: error)
    }

    private func log(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        events.insert("[\(stamp)] \(line)", at: 0)
        if events.count > 40 { events.removeLast(events.count - 40) }
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

    // MARK: - Derived display values

    var uptimeText: String? {
        guard let since = connectedSince else { return nil }
        let seconds = Int(Date().timeIntervalSince(since))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%dj %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)d"
    }
}
