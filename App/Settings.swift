import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Filtering", systemImage: "shield.lefthalf.filled") { FilteringSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(\.store) private var store
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("notifyApprovals") private var notify = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Open Kekkai at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(Color.shu)
                }
                Toggle("Show Kekkai in the menu bar", isOn: $showMenuBar)
                LabeledContent("First-run welcome") {
                    Button("Show Again") { store.welcomeRequested = true; AppDelegate.openMain?() }
                }
                Toggle("Notify me when an app waits for approval", isOn: $notify)
                Toggle("Watch connections when the filter is off", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "watchMode") },
                    set: { on in
                        UserDefaults.standard.set(on, forKey: "watchMode")
                        if on, FilterControl.shared.state != .on { Watcher.shared.start(store) } else if !on { Watcher.shared.stop() }
                    }))
            } footer: {
                Text("Require Approval only works while Kekkai is open. Opening it at login keeps new apps from being blocked while nobody can answer.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("History") {
                LabeledContent("Traffic history") {
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                }
                Text("Kekkai keeps what it has seen on this Mac between launches. Your rules are not affected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Clear all traffic history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { store.clearHistory() }
        } message: {
            Text("Apps, destinations, countries and the activity list start again from empty.")
        }
    }
}

private struct FilteringSettings: View {
    @Environment(\.store) private var store

    var body: some View {
        Form {
            Section {
                Toggle("Block QUIC when the hostname is hidden", isOn: Binding(get: { store.rules.blockUnknownQUIC },
                                                                               set: { v in store.update { $0.blockUnknownQUIC = v } }))
            } footer: {
                Text("Browsers then fall back to a connection where Kekkai can read the server name, so your blocked domains stay blocked. Only applies when you have blocked domains.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Wait for an answer", selection: Binding(get: { store.rules.approvalTimeout },
                                                               set: { v in store.update { $0.approvalTimeout = v } })) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                }
            } header: {
                Text("Require Approval")
            } footer: {
                Text("A connection nobody answers in time is blocked. Most apps give up waiting after about 75 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(!store.connected)
    }
}

private struct AboutSettings: View {
    var body: some View { AboutView().frame(maxWidth: .infinity) }
}
