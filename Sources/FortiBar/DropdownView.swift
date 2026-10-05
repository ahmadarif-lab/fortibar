import AppKit
import FortiBarCore
import SwiftUI

/// The dropdown: status, details, actions, toggles and a small event log.
struct DropdownView: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            content
            Divider().opacity(0.4)
            footer
        }
        .frame(width: Theme.panelWidth)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.phase.symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.color(for: model.phase))
            VStack(alignment: .leading, spacing: 1) {
                Text("FortiBar").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(Theme.color(for: model.phase)).frame(width: 7, height: 7)
                    Text(model.phase.title).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.busy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Body

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let profile = model.selectedProfile {
                infoRow("Profil", profile.name)
                if let server = profile.server { infoRow("Gateway", server) }
                if let user = profile.username { infoRow("Username", user) }
            } else {
                Text("Tidak ada profil FortiClient").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if model.isConnected {
                if let address = model.address { infoRow("IP tunnel", address) }
                if let uptime = model.uptimeText { infoRow("Uptime", uptime) }
            }

            if case .error(let message) = model.phase {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                    Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.danger.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            ForEach(model.doctorChecks) { check in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "stethoscope").foregroundStyle(Theme.connecting)
                    Text(check.message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.connecting.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            actionButtons
            toggles
            eventLog
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var actionButtons: some View {
        VStack(spacing: 6) {
            Button(action: { model.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: model.isConnected ? "bolt.slash.fill" : "bolt.fill")
                    Text(model.isConnected ? "Disconnect" : "Connect")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isConnected ? Theme.danger : Theme.accent)
            .disabled(model.isConnected ? !model.canDisconnect : !model.canConnect)

            Button(action: model.openFortiClient) {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                    Text("Buka FortiClient (kode OTP)")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
        }
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $model.autoReconnect) {
                Text("Auto-reconnect").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Toggle(isOn: $model.launchAtLogin) {
                Text("Mulai saat login").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }

    private var eventLog: some View {
        Group {
            if !model.events.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.events.prefix(12), id: \.self) { line in
                            Text(line)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Log").font(.system(size: 11))
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                Task { await model.refresh(); await model.runDoctor() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Helpers

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
