import FortiBarCore
import SwiftUI

/// Settings window: one form laid out like FortiClient's "Edit VPN Connection"
/// (name, gateway, pre-shared key, username, password), then the one-time
/// helper install. PSK and password go to the keychain, never to the JSON file.
struct ProfileEditorView: View {
    @ObservedObject var model: AppModel

    @State private var editingID: String?
    @State private var isNew = false
    @State private var draft: NativeProfile = .fresh(name: "")
    @State private var routesText = ""
    @State private var exceptionsText = ""
    @State private var newPSK = ""
    @State private var newPassword = ""
    @State private var showAdvanced = false
    @State private var message: String?
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                form
                footer
                Divider()
                general
                Divider()
                system
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 560)
        .onAppear {
            if let id = model.selectedID { load(id) } else { startNew() }
            Task { await model.refreshHelperStatus() }
        }
        .confirmationDialog("Delete this profile?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = editingID { model.delete(id: id) }
                if let next = model.selectedID { load(next) } else { startNew() }
            }
        } message: {
            Text("Its saved pre-shared key and password are removed from the keychain too.")
        }
    }

    private var editingActiveProfile: Bool {
        !isNew && model.isConnected && editingID == model.activeID
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isNew ? "New VPN connection" : "Edit VPN connection").font(.headline)
                Spacer()
                Button("New") { startNew() }
                Button("Delete", role: .destructive) { confirmDelete = true }
                    .disabled(isNew || editingActiveProfile)
            }
            if editingActiveProfile {
                Label("This profile is connected. Disconnect to delete it.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.profiles.count > 1 {
                Picker("Profile", selection: Binding(
                    get: { isNew ? "" : (editingID ?? "") },
                    set: { id in model.select(id); load(id) }
                )) {
                    ForEach(model.profiles) { Text($0.name).tag($0.id) }
                }
            }
        }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            TextField("Connection name", text: $draft.name)
            TextField("Remote gateway", text: $draft.gateway, prompt: Text("IPv4 or hostname"))
            SecureField("Pre-shared key", text: $newPSK, prompt: Text(savedPrompt(.psk)))
            TextField("Username", text: $draft.username)
            SecureField("Password", text: $newPassword, prompt: Text(savedPrompt(.password)))

            DisclosureGroup("Advanced settings", isExpanded: $showAdvanced) {
                TextField("Peer ID", text: $draft.peerID, prompt: Text("optional"))
                TextField("VPN subnets", text: $routesText, prompt: Text("comma separated CIDR"))
                TextField("Keep on LAN", text: $exceptionsText, prompt: Text("comma separated CIDR"))
                TextField("IKE proposals", text: $draft.ike)
                TextField("ESP proposals", text: $draft.esp)
                Toggle("Route virtual IP locally", isOn: $draft.routeVIPLocally)
                    .help("Needed when a local proxy such as sshuttle redirects traffic to hosts behind the VPN and connections time out.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                Text("Pre-shared key and password are stored in your macOS keychain. Leave them empty to keep what is saved. The FortiToken code is never stored; you enter it each time you connect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let id = editingID, !isNew, hasSaved(.psk) || hasSaved(.password) {
                Button("Remove saved credentials", role: .destructive) { model.clearCredentials(profile: id) }
            }
            Button("Save") { commit() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.gateway.isEmpty || draft.username.isEmpty)
        }
    }

    private func hasSaved(_ kind: SecretStore.SecretKind) -> Bool {
        guard let id = editingID, !isNew else { return false }
        return model.hasCredential(kind, profile: id)
    }

    private func savedPrompt(_ kind: SecretStore.SecretKind) -> String {
        hasSaved(kind) ? "saved — type to replace" : "required"
    }

    // MARK: - General

    private var general: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("General").font(.headline)
            Toggle("Launch FortiBar at login", isOn: $model.launchAtLogin)
            Toggle("Check for updates automatically", isOn: $model.checkUpdatesAutomatically)
            HStack {
                Button("Check for updates") { Task { await model.checkForUpdate(manual: true) } }
                    .disabled(model.checkingForUpdate)
                if model.checkingForUpdate { ProgressView().controlSize(.small) }
                if let release = model.availableUpdate {
                    Text("Version \(release.version) is available.").font(.callout)
                    Button("Release notes") { model.openRelease() }.buttonStyle(.link)
                    Button("Copy brew command") { model.copyUpgradeCommand() }.buttonStyle(.link)
                }
            }
            if let text = model.updateCheckMessage {
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            Text("FortiBar \(model.versionLabel)").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - System

    private var system: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System").font(.headline)
            Text("A small background helper runs the VPN engine with the privileges it needs. Installing it asks for administrator approval (Touch ID) once; connecting afterwards needs only the FortiToken code.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Label(helperTitle, systemImage: model.helperStatus == .ready ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.callout)
                    .foregroundStyle(model.helperStatus == .ready ? Theme.connected : Theme.connecting)
                Spacer()
                if model.helperBusy { ProgressView().controlSize(.small) }
                Button(model.helperStatus == .outdated ? "Update helper" : "Install helper") { model.installHelper() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.helperBusy || model.helperStatus == .ready || model.helperStatus == .missingStrongSwan)
                Button("Remove helper", role: .destructive) { model.uninstallHelper() }
                    .disabled(model.helperBusy || model.helperStatus == .notInstalled || model.isConnected)
            }
            if model.isConnected {
                Label("Disconnect the VPN to remove the helper.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let text = model.helperMessage {
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            if model.helperStatus == .missingStrongSwan {
                Text("strongSwan is required: run  brew install strongswan  in Terminal, then reopen this window.")
                    .font(.callout).foregroundStyle(Theme.connecting)
            }
        }
    }

    private var helperTitle: String {
        switch model.helperStatus {
        case .ready: return "Helper running"
        case .notInstalled: return "Helper not installed"
        case .outdated: return "Helper needs an update"
        case .missingStrongSwan: return "Helper running, strongSwan missing"
        }
    }

    // MARK: - Actions

    private func startNew() {
        draft = .fresh(name: "")
        routesText = draft.routes.joined(separator: ", ")
        exceptionsText = ""
        editingID = draft.id
        isNew = true
        newPSK = ""
        newPassword = ""
        message = nil
    }

    private func load(_ id: String) {
        guard let profile = model.profiles.first(where: { $0.id == id }) else { return }
        draft = profile
        routesText = profile.routes.joined(separator: ", ")
        exceptionsText = profile.lanExceptions.joined(separator: ", ")
        editingID = id
        isNew = false
        newPSK = ""
        newPassword = ""
        message = nil
    }

    private func commit() {
        draft.routes = split(routesText)
        draft.lanExceptions = split(exceptionsText)
        guard !draft.routes.isEmpty, (draft.routes + draft.lanExceptions).allSatisfy(HelperValidation.isIPv4CIDR) else {
            showAdvanced = true
            message = "Subnets must be IPv4 CIDR (e.g. 10.0.0.0/8), at least one."
            return
        }
        model.save(draft)
        if !newPSK.isEmpty || !newPassword.isEmpty {
            model.updateCredentials(profile: draft.id, psk: newPSK, password: newPassword)
        }
        newPSK = ""
        newPassword = ""
        editingID = draft.id
        isNew = false
        message = model.isComplete(draft.id) ? "Saved." : "Saved. Add the pre-shared key and password to connect."
    }

    private func split(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
