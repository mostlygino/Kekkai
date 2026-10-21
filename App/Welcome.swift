import ServiceManagement
import SwiftUI

/// The first-run welcome: six short steps in a sheet over the main window. Shown once (or again from
/// Help > Welcome to Kekkai). It shows the user's own traffic as soon as it can, has them pick how Kekkai
/// protects this Mac, shows where blocking lives, and sets the few preferences that matter on day one.
struct WelcomeFlow: View {
    enum Step: Int, CaseIterable {
        case welcome, live, protection, blocking, preferences, ready
    }

    enum Protection: String, CaseIterable, Identifiable {
        case watch, firewall, filter
        var id: String { rawValue }
    }

    @Environment(\.store) private var store
    @Environment(\.filter) private var filter
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("onboardingDone") private var done = false
    @AppStorage("watchMode") private var watchMode = false

    @State private var step: Step = Demo.welcomeStep.flatMap(Step.init(rawValue:)) ?? .welcome
    @State private var forward = true
    @State private var protection: Protection = FilterControl.canLoadFilter ? .filter : .firewall

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content
                    .id(step)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .background { RakedGround(center: .init(x: 0.5, y: 0.2), rings: 16) }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .live: LiveStep()
        case .protection: ProtectionStep(choice: $protection)
        case .blocking: BlockingStep(protection: protection)
        case .preferences: PreferencesStep(protection: protection)
        case .ready: ReadyStep(protection: protection)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Back") { go(-1) }
                .keyboardShortcut("[", modifiers: .command)
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)
            Spacer()
            StepStones(count: Step.allCases.count, current: step.rawValue)
            Spacer()
            if step == .ready {
                Button("Open Kekkai") { finish() }
                    .buttonStyle(.borderedProminent).tint(Color.shu)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(step == .welcome ? "Get Started" : "Continue") { go(1) }
                    .buttonStyle(.borderedProminent).tint(Color.shu)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func go(_ delta: Int) {
        // Leaving the choice step applies it, so the next steps already describe what is running.
        if step == .protection && delta > 0 { apply(protection) }
        // Seeing your own traffic is the best first impression: start watching on the way to that step.
        if step == .welcome && delta > 0, !store.watching, !store.connected { Watcher.shared.start(store) }
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.35)) { step = next }
    }

    private func apply(_ choice: Protection) {
        guard !Demo.isOn else { return }
        switch choice {
        case .watch, .firewall:
            watchMode = true
            if !store.watching { Watcher.shared.start(store) }
        case .filter:
            watchMode = true                 // keeps watching whenever the filter is off
            if filter.state != .on { filter.turnOn() }
        }
    }

    private func finish() {
        done = true
        if protection == .firewall { store.show(.rules) }
        dismissWindow(id: "welcome")
    }
}

// MARK: Progress

/// Progress as a row of small stones: done ones tied in vermilion, the current one larger.
private struct StepStones: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                StoneShape()
                    .fill(i <= current ? Color.shu : Color.secondary.opacity(0.35))
                    .frame(width: i == current ? 16 : 10, height: i == current ? 16 : 10)
                    .animation(.snappy(duration: 0.3), value: current)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: 1. Welcome

private struct WelcomeStep: View {
    @State private var ripple: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                // Three rings spread through the gravel around the stone, once.
                ForEach(0..<3) { i in
                    Ellipse()
                        .stroke(Color.shu.opacity(0.5 - Double(i) * 0.14), lineWidth: 1.2)
                        .frame(width: 150, height: 122)
                        .scaleEffect(1 + ripple * (0.35 + CGFloat(i) * 0.3))
                        .opacity(1 - Double(ripple) * 0.6)
                }
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 132, height: 132)
                    .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
            }
            .frame(height: 190)
            .onAppear { if !reduceMotion { withAnimation(.easeOut(duration: 1.6)) { ripple = 1 } } }

            VStack(spacing: 8) {
                Text("Welcome to Kekkai").font(.garden(.largeTitle))
                Text("結界 · A BARRIER FOR YOUR MAC")
                    .font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(Color.shu)
            }
            Text("Kekkai shows every app that talks to the network, where it goes and how much it sends, and stops the ones you don't trust. Nothing it sees ever leaves this Mac.")
                .font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)

            HStack(spacing: 28) {
                Feature(symbol: "eye", title: "See", detail: "Every app, every destination")
                Feature(symbol: "lock.shield", title: "Block", detail: "Apps, domains, addresses")
                Feature(symbol: "command", title: "Find", detail: "Anything with ⌘K")
            }
            .padding(.top, 6)
        }
        .padding(32)
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.shu).frame(height: 26)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 150)
        .accessibilityElement(children: .combine)
    }
}

// MARK: 2. Live

/// The user's own Mac, live: counters that tick up and the busiest apps arriving as Watch mode sees them.
private struct LiveStep: View {
    @Environment(\.store) private var store

    var body: some View {
        let apps = store.apps.values.sorted { $0.connections > $1.connections }.prefix(5)
        let t = store.totals
        let countries = Set(store.destinations.compactMap(\.country)).count

        VStack(alignment: .leading, spacing: 20) {
            StepTitle(title: "This is what's talking to the internet",
                      detail: "Kekkai reads macOS's own list of connections. Nothing is blocked yet; you're only looking.")
            HStack(spacing: 14) {
                Counter(value: store.apps.count, label: "apps")
                Counter(value: t.connections, label: "connections")
                // Builds without the GeoIP file (it isn't in git) can't place anything in a country:
                // count destinations there instead of showing a misleading 0.
                if GeoIP.available {
                    Counter(value: countries, label: countries == 1 ? "country" : "countries")
                } else {
                    Counter(value: store.destinations.count, label: store.destinations.count == 1 ? "destination" : "destinations")
                }
            }
            VStack(spacing: 0) {
                if apps.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Listening for the first connections…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider().padding(.leading, 46) }
                        HStack(spacing: 12) {
                            Image(nsImage: a.app.icon).resizable().frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.app.title).lineLimit(1)
                                Text("\(a.destinations.count) \(a.destinations.count == 1 ? "destination" : "destinations")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(bytes(a.bytesIn + a.bytesOut)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .animation(.snappy(duration: 0.3), value: apps.map(\.id))
            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
        }
        .padding(.horizontal, 48).padding(.vertical, 32)
    }
}

private struct Counter: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.system(size: 30, weight: .semibold, design: .serif)).monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .animation(.snappy, value: value)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

// MARK: 3. Protection

private struct ProtectionStep: View {
    @Binding var choice: WelcomeFlow.Protection

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepTitle(title: "How should Kekkai protect this Mac?",
                      detail: "You can change this any time from the status pill in the toolbar.")
            VStack(spacing: 10) {
                Option(selected: choice == .watch, symbol: "eye", title: "Just watch",
                       detail: "See every app and destination. Nothing is blocked.") { choice = .watch }
                Option(selected: choice == .firewall, symbol: "lock.shield", title: "Watch and block on this Mac",
                       detail: "Block domains, addresses and apps with macOS's own firewall, for every app. macOS asks for your password when you apply.",
                       badge: FilterControl.canLoadFilter ? nil : "Recommended") { choice = .firewall }
                Option(selected: choice == .filter, symbol: "shield.lefthalf.filled", title: "Network filter",
                       detail: FilterControl.canLoadFilter
                           ? "Block exactly per app, and ask before new apps connect. macOS asks you to allow Kekkai's extension."
                           : "Needs a copy of Kekkai signed by a developer team. This one isn't, so it can't load.",
                       badge: FilterControl.canLoadFilter ? "Recommended" : nil,
                       enabled: FilterControl.canLoadFilter) { choice = .filter }
            }
        }
        .padding(.horizontal, 48).padding(.vertical, 32)
    }
}

private struct Option: View {
    let selected: Bool
    let symbol: String
    let title: String
    let detail: String
    var badge: String?
    var enabled = true
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(selected ? Color.shu : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .foregroundStyle(Color.shu)
                                .background(Color.shu.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.shu : Color.secondary.opacity(0.5))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.shu.opacity(0.08) : Color.clear, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.shu.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: selected ? 1.5 : 1))
            .contentShape(.rect(cornerRadius: 12))
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.snappy(duration: 0.2), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: 4. Blocking

private struct BlockingStep: View {
    let protection: WelcomeFlow.Protection

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(title: "Three ways to stop something",
                      detail: protection == .watch
                          ? "You chose to just watch. When you want to block something, it's always one of these."
                          : "Whichever you use, Kekkai shows what changed and applies it in one step.")
            Way(number: "1", title: "From an app",
                detail: "Select an app in Apps and press Block in the inspector. Kekkai blocks what only that app uses.") {
                Label("Block Dia on This Mac…", systemImage: "lock.shield")
                    .font(.callout.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.shu, in: .rect(cornerRadius: 7))
            }
            Way(number: "2", title: "From anywhere",
                detail: "Press ⌘K, type a domain like ads.example.com, and choose Block.") {
                HStack(spacing: 4) { KeyCap("⌘"); KeyCap("K") }
            }
            Way(number: "3", title: "With your lists",
                detail: "Rules holds your Block List and Allow List. Paste many domains at once; *.example.com covers every subdomain.") {
                HStack(spacing: 6) {
                    SealBadge(size: 15)
                    Text("*.doubleclick.net").font(.callout.monospaced())
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 48).padding(.vertical, 32)
    }
}

private struct Way<Demo: View>: View {
    let number: String
    let title: String
    let detail: String
    @ViewBuilder let demo: Demo

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(number)
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(Color.shu)
                .frame(width: 30, height: 30)
                .background(Color.shu.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            demo.accessibilityHidden(true)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }
}

private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(.title3, design: .rounded).weight(.medium))
            .frame(minWidth: 32, minHeight: 32)
            .background(.background, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.35)))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 2)
    }
}

// MARK: 5. Preferences

private struct PreferencesStep: View {
    let protection: WelcomeFlow.Protection
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("notifyApprovals") private var notify = true
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(title: "Make it yours",
                      detail: "All of these live in Settings later too.")
            VStack(spacing: 0) {
                Pref(symbol: "menubar.rectangle", title: "Show Kekkai in the menu bar",
                     detail: "Status, recently blocked and a live traffic chart, one click away.", isOn: $showMenuBar)
                Divider().padding(.leading, 52)
                Pref(symbol: "power", title: "Open Kekkai at login",
                     detail: protection == .filter ? "So someone is there to answer when a new app wants to connect."
                                                   : "So it's watching from the moment you sign in.",
                     isOn: Binding(get: { atLogin }, set: { on in
                         guard !Demo.isOn else { atLogin = on; return }
                         do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                         catch { NSLog("Kekkai: login item: \(error.localizedDescription)") }
                         atLogin = SMAppService.mainApp.status == .enabled
                     }))
                if protection == .filter {
                    Divider().padding(.leading, 52)
                    Pref(symbol: "bell.badge", title: "Notify me when an app waits",
                         detail: "With Allow and Block right on the notification.", isOn: $notify)
                }
            }
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        }
        .padding(.horizontal, 48).padding(.vertical, 32)
    }
}

private struct Pref: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.shu).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(Color.shu)
        }
        .padding(14)
    }
}

// MARK: 6. Ready

private struct ReadyStep: View {
    @Environment(\.store) private var store
    let protection: WelcomeFlow.Protection

    var body: some View {
        VStack(spacing: 22) {
            BarrierMark(on: true, size: 120)
                .padding(.top, 8)
            VStack(spacing: 8) {
                Text("The stone is in place").font(.garden(.largeTitle))
                Text(summary).font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            HStack(spacing: 18) {
                Tip(keys: "⌘K", text: "Find any app, host or action")
                Tip(keys: "⌘↩", text: "Block what's selected in ⌘K")
                Tip(keys: "⇧⌘K", text: "Raise or lower the barrier")
            }
            .padding(.top, 4)
        }
        .padding(32)
    }

    private var summary: String {
        switch protection {
        case .watch: "Kekkai is watching. Apps appears as soon as they connect; nothing is blocked."
        case .firewall: "Kekkai is watching. Block something from Apps, ⌘K or Rules, then apply it to this Mac."
        case .filter: "Allow Kekkai's extension in System Settings when macOS asks. After that, the barrier is up."
        }
    }
}

private struct Tip: View {
    let keys: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Text(keys).font(.system(.callout, design: .rounded).weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary, in: .rect(cornerRadius: 5))
            Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(width: 150)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Shared

private struct StepTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.garden(.title))
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
