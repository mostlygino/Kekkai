import AppKit
import SwiftUI

/// About Kekkai, laid out as an okuzuke (奥付): the colophon at the back of a Japanese book. It names the
/// edition (版) and the printing (刷), the author (著) presses a seal into a paper slip (検印) to vouch for the
/// copy, and here one more line says how the barrier (結) stands on this Mac right now.
struct AboutView: View {
    static let developer = "Gino de Graaff"
    static let handle = "mostlygino"
    static let website = URL(string: "https://mostlygino.com")!
    static let github = URL(string: "https://github.com/mostlygino")!
    static let repository = URL(string: "https://github.com/mostlygino/Kekkai")!

    @Environment(\.store) private var store
    @Environment(\.filter) private var filter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false
    @State private var bloom = false
    @State private var copied = false
    @State private var checking = false

    private let build = BuildInfo.current

    var body: some View {
        VStack(spacing: 0) {
            hero
                .padding(.top, 40)
                .padding(.horizontal, 32)
            colophon
                .padding(.top, 26)
                .padding(.horizontal, 26)
            actions
                .padding(.top, 18)
            footer
                .padding(.top, 22)
                .padding(.bottom, 24)
                .padding(.horizontal, 32)
        }
        .frame(width: 470)
        .background { WashiGround().ignoresSafeArea() }
        .task { await stamp() }
    }

    // MARK: Title

    private var hero: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.22), radius: 10, y: 6)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Kekkai")
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                Text("結界")
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundStyle(Color.shu)
                    .accessibilityHidden(true)
            }
            Text("A barrier for your Mac. See which apps connect where, and stop the ones you don't trust.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
    }

    // MARK: Colophon

    private var colophon: some View {
        HStack(alignment: .center, spacing: 20) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                entry(mark: "版", label: "Version") {
                    HStack(spacing: 6) {
                        Text(build.version).font(.body.weight(.semibold)).monospacedDigit()
                        channelTag
                    }
                }
                entry(mark: "刷", label: "Build") {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(build.number).font(.system(.callout, design: .monospaced))
                            copyButton
                        }
                        buildDetail
                    }
                }
                entry(mark: "結", label: "Barrier") {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            BarrierMark(on: barrierUp, size: 11, lineWidth: 1.2)
                            Text(barrierUp ? "Up" : "Down").font(.body.weight(.semibold))
                        }
                        Text(barrierDetail).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                entry(mark: "著", label: "Built by") {
                    VStack(alignment: .leading, spacing: 2) {
                        Link(Self.handle, destination: Self.website)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.shu)
                            .help("mostlygino.com")
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.shu)
                                .symbolEffect(.bounce, value: bloom)
                            Text("Built with love by \(Self.developer)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            kenin
        }
        .padding(.vertical, 18)
        .padding(.leading, 18)
        .padding(.trailing, 20)
        .background(Color.shu.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.shu.opacity(0.18), lineWidth: 1))
    }

    private var barrierUp: Bool { filter.state == .on && store.connected }

    private var barrierDetail: String {
        switch filter.state {
        case .on where store.connected: "\(store.rules.mode.title) · \(store.rules.domains.count) blocked · \(store.rules.allowDomains.count) allowed"
        case .on: "Filter on, extension not answering"
        case .needsUserApproval: "Waiting for your approval in System Settings"
        case .failed: "The filter couldn't start"
        default: "Traffic is not inspected"
        }
    }

    private func entry(mark: String, label: LocalizedStringKey, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(mark)
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundStyle(Color.shu)
                .accessibilityHidden(true)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            value()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var channelTag: some View {
        switch build.channel {
        case .beta: ChannelTag(text: "Beta", tint: Color.shu)
        case .development: ChannelTag(text: "Development build", tint: .secondary)
        case .release: EmptyView()
        }
    }

    /// "19 October 2026 · 6699e9c", the commit linking to its page on GitHub.
    @ViewBuilder
    private var buildDetail: some View {
        HStack(spacing: 5) {
            if let date = build.date {
                Text(date, format: .dateTime.day().month(.wide).year())
            }
            if build.date != nil, build.commit != nil { Text("·").accessibilityHidden(true) }
            if let commit = build.commit {
                Link(commit, destination: Self.repository.appendingPathComponent("commit/\(commit)"))
                    .font(.system(.caption, design: .monospaced))
                    .help("Show this commit on GitHub")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: The seal

    /// The 検印 slip: a scrap of paper the author stamps by hand, here with the mostlygino.com icon.
    /// Click it to stamp again.
    private var kenin: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.paper)
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .strokeBorder(Color.shu.opacity(0.35), lineWidth: 0.75)
                    .padding(5)
                Ellipse()
                    .stroke(Color.shu, lineWidth: 2)
                    .frame(width: 64, height: 52)
                    .scaleEffect(bloom ? 1.45 : 1)
                    .opacity(pressed && !bloom ? 0.5 : 0)
                Image("Developer")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 62, height: 62)
                    .rotationEffect(.degrees(-6))
                    .shadow(color: .black.opacity(pressed ? 0.25 : 0), radius: pressed ? 2 : 8, y: pressed ? 1 : 6)
                    .scaleEffect(pressed ? 1 : 1.6)
                    .opacity(pressed ? 1 : 0)
                    .blur(radius: pressed ? 0 : 5)
            }
            .frame(width: 82, height: 82)
            .rotationEffect(.degrees(1.5))
            .shadow(color: .black.opacity(0.14), radius: 2, y: 1.5)
            .contentShape(Rectangle())
            .onTapGesture { Task { await stamp() } }
            Text("検印")
                .font(.system(size: 10, weight: .medium, design: .serif))
                .tracking(3)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.handle) seal")
    }

    /// The one authored moment: the seal drops, lands with a tap you can feel on the trackpad, and its
    /// ink spreads out like a ripple in raked gravel.
    private func stamp() async {
        guard !reduceMotion else { pressed = true; return }
        pressed = false
        bloom = false
        try? await Task.sleep(for: .milliseconds(320))
        withAnimation(.easeIn(duration: 0.2)) { pressed = true }
        try? await Task.sleep(for: .milliseconds(200))
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        withAnimation(.easeOut(duration: 0.7)) { bloom = true }
    }

    // MARK: Actions

    /// Copies version, build, commit, filter state and macOS as plain text for a bug report.
    private var copyButton: some View {
        Button {
            copy(build.report(barrier: barrierDetail))
            withAnimation(.snappy) { copied = true }
            Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation(.snappy) { copied = false } }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? Color.shu : .secondary)
        .help("Copy version info for a bug report")
        .accessibilityLabel(copied ? "Copied" : "Copy version info")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Release Notes") { NSWorkspace.shared.open(releaseNotes) }
                .help(build.channel == .development ? "Show the latest changes on GitHub" : "Show what changed in \(build.version)")
            Button {
                checking = true
                Task { await Updater.shared.check(interactive: true); checking = false }
            } label: {
                HStack(spacing: 6) {
                    if checking { ProgressView().controlSize(.mini) }
                    Text("Check for Updates…")
                }
            }
            .disabled(checking)
            .help("Look for a newer signed release on GitHub")
        }
        .buttonStyle(.glass)
    }

    private var releaseNotes: URL {
        build.channel == .development
            ? Self.repository.appendingPathComponent("commits/main")
            : Self.repository.appendingPathComponent("releases/tag/v\(build.version)")
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Text(["macOS \(BuildInfo.macOS)", BuildInfo.architecture, GeoIP.available ? "GeoIP bundled" : "No GeoIP data"]
                .joined(separator: "  ·  "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Link("mostlygino.com", destination: Self.website)
                Link("GitHub", destination: Self.github)
                Link("Feedback", destination: Self.repository.appendingPathComponent("issues/new"))
                    .help("Report a problem or suggest something")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.shu)
            VStack(spacing: 3) {
                Text("Nothing Kekkai sees leaves this Mac.")
                HStack(spacing: 4) {
                    Text("Map outlines from")
                    Link("Natural Earth", destination: URL(string: "https://www.naturalearthdata.com")!)
                    Text("· IP to country by")
                    Link("DB-IP", destination: GeoIP.attributionURL)
                    Text("(CC BY 4.0)")
                }
                Text("© 2026 \(Self.developer). Free software under the AGPL-3.0.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }
}

private struct ChannelTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: Build info

/// What this copy of Kekkai is. Commit and date are stamped into Info.plist after each build
/// (project.yml, "Stamp build info"); the channel comes from scripts/release.sh.
struct BuildInfo {
    enum Channel: String { case development = "Development", beta = "Beta", release = "Release" }

    let version: String
    let number: String
    let channel: Channel
    let commit: String?
    let date: Date?

    static let current: BuildInfo = {
        let info = Bundle.main.infoDictionary ?? [:]
        let commit = info["KekkaiCommit"] as? String
        return BuildInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "?",
            number: info["CFBundleVersion"] as? String ?? "?",
            channel: Channel(rawValue: info["KekkaiChannel"] as? String ?? "") ?? .development,
            commit: commit == "unknown" || commit?.isEmpty == true ? nil : commit,
            date: (info["KekkaiBuildDate"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        )
    }()

    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    static var architecture: String {
        #if arch(arm64)
        "Apple silicon"
        #else
        "Intel"
        #endif
    }

    /// Plain text for a bug report.
    func report(barrier: String) -> String {
        let channelName = channel == .release ? "" : " \(channel.rawValue)"
        var lines = ["Kekkai \(version)\(channelName) (build \(number))"]
        if let commit { lines.append("Commit \(commit)") }
        if let date { lines.append("Built \(date.formatted(.iso8601))") }
        lines.append("Barrier: \(barrier)")
        lines.append("macOS \(Self.macOS), \(Self.architecture)")
        return lines.joined(separator: "\n")
    }
}

// MARK: Ground

/// Washi: the window ground with a few long paper fibres, too faint to read as a pattern.
private struct WashiGround: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor).overlay {
            Canvas { context, size in
                var seed: UInt64 = 0x6B6B
                func next() -> CGFloat {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
                }
                for _ in 0..<110 {
                    let start = CGPoint(x: next() * size.width, y: next() * size.height)
                    let angle = next() * .pi * 2
                    let length = 10 + next() * 26
                    let end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
                    let bend = CGPoint(x: (start.x + end.x) / 2 + (next() - 0.5) * 10, y: (start.y + end.y) / 2 + (next() - 0.5) * 10)
                    var fibre = Path()
                    fibre.move(to: start)
                    fibre.addQuadCurve(to: end, control: bend)
                    context.stroke(fibre, with: .color(.primary.opacity(0.035 + next() * 0.03)), lineWidth: 0.4 + next() * 0.7)
                }
            }
            .accessibilityHidden(true)
        }
    }
}
