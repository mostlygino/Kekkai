import SwiftUI

@main
struct KekkaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: Store
    @State private var filter: FilterControl
    @AppStorage("showMenuBar") private var showMenuBar = true

    init() {
        let store = Store.shared
        let filter = FilterControl.shared
        // The filter's own events replace Watch mode while it runs; Watch mode comes back when it stops.
        filter.onEnabled = { Watcher.shared.stop(); store.connect() }
        filter.onDisabled = {
            store.disconnect()
            if UserDefaults.standard.bool(forKey: "watchMode") { Watcher.shared.start(store) }
        }
        Alerts.shared.attach(store)
        DispatchQueue.main.async {
            Demo.start(store)
            Updater.shared.checkInBackground()
            if UserDefaults.standard.bool(forKey: "watchMode"), filter.state != .on { Watcher.shared.start(store) }
        }
        _store = State(initialValue: store)
        _filter = State(initialValue: filter)
    }

    var body: some Scene {
        Window("Kekkai", id: "main") {
            ContentView()
                .environment(store)
                .environment(filter)
        }
        .defaultSize(width: 1320, height: 820)
        .defaultLaunchBehavior(.presented)
        // Not restored: after a force quit, restoration said "no windows" and the window never came back.
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
                Button("Check for Updates…") { Task { await Updater.shared.check(interactive: true) } }
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to Kekkai…") { store.welcomeRequested = true; AppDelegate.openMain?() }
                Link("Kekkai on GitHub", destination: AboutView.repository)
            }
            CommandGroup(after: .appSettings) {
                Button("Uninstall Kekkai…") { Uninstaller.run(filter: filter) }
            }
            CommandGroup(after: .textEditing) {
                Button("Command Palette…") { CommandPalette.shared.toggle() }
                    .keyboardShortcut("k")
            }
            CommandMenu("Barrier") {
                Button(filter.state == .on ? "Lower Barrier" : "Raise Barrier") {
                    filter.state == .on ? filter.turnOff() : filter.turnOn()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Picker("Mode", selection: Binding(get: { store.rules.mode }, set: { m in store.update { $0.mode = m } })) {
                    ForEach(Array(FilterMode.allCases.enumerated()), id: \.element) { i, mode in
                        Text(mode.title).tag(mode).keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                    }
                }
                .pickerStyle(.inline)
                .disabled(!store.connected)
            }
        }

        Window("Waiting for Approval", id: "approvals") {
            ApprovalPanel()
                .environment(store)
        }
        .windowStyle(.plain)
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.topTrailing)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel()
                .environment(store)
                .environment(filter)
        } label: {
            MenuBarLabel(store: store, filter: filter)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Kekkai", id: "welcome") {
            WelcomeFlow()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Window("About Kekkai", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        // Demo tour only: the menu bar panel in a normal window, so it can be looked at and captured.
        Window("Menu Bar Preview", id: "demo-menubar") {
            MenuBarPanel()
                .environment(store)
                .environment(filter)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About Kekkai") { openWindow(id: "about"); NSApp.activate() }
    }
}
