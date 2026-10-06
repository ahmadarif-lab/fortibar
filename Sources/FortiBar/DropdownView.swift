import AppKit
import FortiBarCore
import SwiftUI

/// The dropdown: status, profile, connect action, a toggle and a small log.
struct DropdownView: View {
    @ObservedObject var model: AppModel

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
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("FortiBar").font(.system(size: 13, weight: .semibold))
                    Text(model.versionLabel).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 5) {
                    Circle().fill(Theme.color(for: model.phase)).frame(width: 7, height: 7)
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusText: String {
        guard model.isConnected else { return model.phase.title }
        return ["Connected", model.activeProfile?.name, model.uptimeText].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Body

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            profileSection
            if let release = model.availableUpdate { updateBanner(release) }
            if let message = model.helperStatus.message {
                notice(message, color: Theme.connecting, symbol: "wrench.and.screwdriver")
            }
            if case .error(let message) = model.phase {
                notice(message, color: Theme.danger, symbol: "exclamationmark.triangle.fill")
            }
            actions
            eventLog
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var profileSection: some View {
        if model.profiles.isEmpty {
            Text("No VPN profile yet. Add one in Settings.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else if model.isConnected, let profile = model.activeProfile {
            // Connected: only the live profile, no choice to make.
            infoRow("Profile", profile.name)
            infoRow("Gateway", profile.gateway)
            infoRow("Username", profile.username)
            if let address = model.address { infoRow("Address", address) }
        } else {
            // Inline list rather than a pop-up menu: the menu takes key focus
            // away from this panel, which then closes before the choice lands.
            if model.profiles.count > 1 {
                VStack(spacing: 2) {
                    ForEach(model.profiles) { profile in
                        ProfileChoice(model: model, profile: profile)
                    }
                }
            }
            if let profile = model.selectedProfile {
                if model.profiles.count == 1 { infoRow("Profile", profile.name) }
                infoRow("Gateway", profile.gateway)
                infoRow("Username", profile.username)
            }
        }
    }

    private func updateBanner(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                Text("FortiBar \(release.version) is available").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button { model.dismissUpdate() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide until the next version")
            }
            HStack(spacing: 8) {
                if let step = model.updateProgress {
                    ProgressView().controlSize(.small)
                    Text(step).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Button("Install") { model.installUpdate() }
                    Button("Release notes") { model.openRelease() }
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            if let text = model.updateError ?? model.updateCheckMessage {
                Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Actions

    @ViewBuilder private var actions: some View {
        if let profile = model.selectedProfile {
            VStack(alignment: .leading, spacing: 6) {
                if !model.selectedIsActive {
                    TextField("FortiToken code (6 digits)", text: $model.otp)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.otp) { _, value in
                            let digits = String(value.filter(\.isNumber).prefix(6))
                            if digits != value { model.otp = digits }
                        }
                        .onSubmit { if model.canConnect { model.connect() } }
                }

                Button(action: { model.toggle() }) {
                    HStack(spacing: 6) {
                        Image(systemName: model.selectedIsActive ? "bolt.slash.fill" : "bolt.fill")
                        Text(model.selectedIsActive ? "Disconnect" : "Connect")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.selectedIsActive ? Theme.danger : Theme.accent)
                .disabled(model.selectedIsActive ? !model.canDisconnect : !model.canConnect)

                if !model.selectedIsActive, !model.isComplete(profile.id) {
                    Text("Add the pre-shared key and password in Settings first.")
                        .font(.system(size: 10)).foregroundStyle(Theme.connecting)
                }
            }
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
        HStack(spacing: 14) {
            footerButton("Settings", symbol: "gearshape") { SettingsWindow.show(model: model) }
            Spacer()
            footerButton("Quit", symbol: nil) { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func footerButton(_ title: String, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let symbol {
                Label(title, systemImage: symbol).font(.system(size: 11))
            } else {
                Text(title).font(.system(size: 11))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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

    private func notice(_ text: String, color: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .copyableOnContextMenu(text)
    }
}

/// One selectable profile in the inline list.
private struct ProfileChoice: View {
    @ObservedObject var model: AppModel
    let profile: NativeProfile
    @State private var isHovering = false

    private var isSelected: Bool { model.selectedID == profile.id }

    var body: some View {
        Button { model.select(profile.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary.opacity(0.6))
                Text(profile.name).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Spacer()
                if !model.isComplete(profile.id) {
                    Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(Theme.connecting)
                        .help("Credentials missing")
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.08) : (isHovering ? Color.primary.opacity(0.05) : .clear))
        )
        .onHover { isHovering = $0 }
    }
}
