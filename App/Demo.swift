import AppKit

/// Synthetic traffic for UI work and screenshots. Only runs with the `-demo` launch argument,
/// and feeds the same `Store.ingest` path the extension's events take.
enum Demo {
    static let isOn = CommandLine.arguments.contains("-demo")
    /// `-demoOffline`: as if the filter can't load (no developer account): Watch mode and the system firewall.
    static let offline = isOn && CommandLine.arguments.contains("-demoOffline")
    /// `-demoOnboarding`: a first launch, no traffic yet (pair with -demoOffline for an unsigned build).
    static let onboarding = isOn && CommandLine.arguments.contains("-demoOnboarding")
    /// `-demoWelcome` shows the first-run welcome; `-demoWelcomeStep 3` opens it on that step (0-based).
    static let welcome = isOn && CommandLine.arguments.contains("-demoWelcome")
    static var welcomeStep: Int? { welcome && UserDefaults.standard.object(forKey: "demoWelcomeStep") != nil ? UserDefaults.standard.integer(forKey: "demoWelcomeStep") : nil }
    /// `-demoPane map` opens on that pane; `-demoAppearance light|dark` pins the appearance. For screenshots.
    /// `-demoTour` walks through every pane, three seconds each, so one launch can be checked end to end.
    static let tour = isOn && CommandLine.arguments.contains("-demoTour")
    /// Also outside demo mode: `-pane activity` opens on that pane (launch argument only, never stored).
    static var pane: Pane? { UserDefaults.standard.string(forKey: isOn ? "demoPane" : "pane").flatMap(Pane.init(rawValue:)) }

    private struct App {
        let id: AppIdentity
        let weight: Int
        let hosts: [(host: String?, ip: String, port: String)]
    }

    private static func app(_ name: String, _ path: String, team: String? = nil, apple: Bool = false, signing: String? = nil,
                            weight: Int, _ hosts: [(String?, String, String)]) -> App {
        App(id: AppIdentity(signingID: signing ?? "com.\(name.lowercased().replacingOccurrences(of: " ", with: ""))",
                            teamID: team, isApple: apple, path: path),
            weight: weight, hosts: hosts.map { (host: $0.0, ip: $0.1, port: $0.2) })
    }

    private static let apps: [App] = [
        app("Safari", "/Applications/Safari.app", apple: true, signing: "com.apple.Safari", weight: 9, [
            ("www.apple.com", "17.253.144.10", "443"), ("en.wikipedia.org", "185.15.59.224", "443"),
            ("news.yahoo.co.jp", "183.79.250.123", "443"), ("g1.globo.com", "186.192.90.5", "443"),
            ("www.abc.net.au", "203.2.218.214", "443"), ("www.svt.se", "194.71.172.9", "443"),
            ("www.lemonde.fr", "213.186.33.4", "443"), ("www.ndtv.com", "103.27.9.20", "443"),
            ("fonts.gstatic.com", "142.250.179.163", "443"), ("cdn.jsdelivr.net", "104.16.85.20", "443"),
        ]),
        app("Mail", "/System/Applications/Mail.app", apple: true, signing: "com.apple.mail", weight: 3, [
            ("imap.mail.me.com", "17.42.251.41", "993"), ("smtp.mail.me.com", "17.42.251.56", "587"),
        ]),
        app("Google Chrome", "/Applications/Google Chrome.app", team: "K7QH2MXW4P", signing: "com.google.Chrome", weight: 10, [
            ("www.google.com", "142.250.179.196", "443"), ("i.ytimg.com", "142.250.179.150", "443"),
            ("accounts.google.com", "142.251.36.13", "443"), ("stats.doubleclick.net", "142.251.39.98", "443"),
            ("www.figma.com", "13.224.103.60", "443"), ("github.com", "140.82.121.4", "443"),
            (nil, "142.250.179.142", "443"),
        ]),
        app("Slack", "/Applications/Slack.app", team: "B3R8VNZ2LD", signing: "com.tinyspeck.slackmacgap", weight: 6, [
            ("wss-primary.slack.com", "3.120.85.17", "443"), ("edgeapi.slack.com", "3.66.104.31", "443"),
            ("files.slack.com", "18.66.122.80", "443"),
        ]),
        app("Spotify", "/Applications/Spotify.app", team: "T2FN5A47ZR", signing: "com.spotify.client", weight: 5, [
            ("spclient.wg.spotify.com", "35.186.224.25", "443"), ("apresolve.spotify.com", "35.186.224.53", "443"),
            ("audio-ak.spotifycdn.com", "2.16.186.11", "443"),
        ]),
        app("Visual Studio Code", "/Applications/Visual Studio Code.app", team: "U8F3T46G9Q", signing: "com.microsoft.VSCode", weight: 4, [
            ("update.code.visualstudio.com", "13.107.246.43", "443"), ("marketplace.visualstudio.com", "13.107.42.18", "443"),
            ("dc.services.visualstudio.com", "20.42.65.92", "443"),
        ]),
        app("Docker", "/Applications/Docker.app", team: "9B5SXJN6RK", signing: "com.docker.docker", weight: 2, [
            ("registry-1.docker.io", "54.227.20.253", "443"), ("production.cloudflare.docker.com", "104.16.98.215", "443"),
        ]),
        app("curl", "/usr/bin/curl", apple: true, signing: "com.apple.curl", weight: 1, [
            ("api.github.com", "140.82.121.6", "443"), ("raw.githubusercontent.com", "185.199.108.133", "443"),
        ]),
        app("softwareupdated", "/System/Library/PrivateFrameworks/SoftwareUpdate.framework/Resources/softwareupdated",
            apple: true, signing: "com.apple.softwareupdated", weight: 1, [
            ("swscan.apple.com", "17.253.53.207", "443"),
        ]),
        app("Sync Helper", "/Users/Shared/.synchelper/sync-helper", signing: nil, weight: 1, [
            (nil, "95.163.33.18", "8443"), (nil, "114.114.114.114", "53"), ("cfg.synchelper-cdn.net", "45.32.112.9", "443"),
        ]),
    ]

    private static var flows: [(event: FlowEvent, ttl: Int)] = []
    private static var timer: Timer?

    static func start(_ store: Store) {
        guard isOn, timer == nil else { return }
        // Appearance first: the onboarding variant returns early and must still honour -demoAppearance.
        switch UserDefaults.standard.string(forKey: "demoAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if onboarding { return }
        store.update {
            $0.mode = .requireApproval
            $0.domains = ["doubleclick.net", "dc.services.visualstudio.com", "app-measurement.com"]
            $0.apps = [apps[2].id.key: true, apps[3].id.key: true, apps[9].id.key: false]
        }
        if offline { store.setWatching(true) } else { store.connect() }

        // Five minutes of history, then live traffic.
        let now = Date()
        for s in stride(from: -300, through: 0, by: 2) { tick(store, at: now.addingTimeInterval(TimeInterval(s)), burst: 2) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in tick(store, at: Date(), burst: 1) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let pdf = AppIdentity(signingID: "com.pdfconvertpro.mac", teamID: nil, isApple: false,
                                  path: "/Users/demo/Downloads/PDF Converter Pro.app")
            store.setApprovals([
                ApprovalRequest(app: pdf, hosts: ["api.pdfconvertpro.io", "track.adnetwork-metrics.com"],
                                ips: ["104.21.48.13", "47.88.61.204"], ports: ["443"], count: 7, since: Date()),
            ])
        }
    }

    private static func tick(_ store: Store, at date: Date, burst: Int) {
        var events: [FlowEvent] = []
        for _ in 0..<Int.random(in: 1...(burst + 1)) {
            let app = weighted()
            guard let h = app.hosts.randomElement() else { continue }
            let decision = store.rules.decide(app: app.id.key, isApple: app.id.isApple, host: h.host, loopback: false)
            let verdict: Verdict = decision.verdict == .ask ? .allow : decision.verdict
            let e = FlowEvent(kind: .opened, flowID: UUID(), app: app.id, host: h.host, ip: h.ip, port: h.port,
                              proto: h.port == "53" ? "UDP" : "TCP", inbound: false, verdict: verdict,
                              reason: decision.reason, date: date)
            events.append(e)
            if verdict == .allow { flows.append((e, Int.random(in: 2...14))) }
        }
        for i in flows.indices.reversed() {
            var e = flows[i].event
            flows[i].ttl -= 1
            let heavy = e.app.signingID == "com.spotify.client" || e.host?.contains("ytimg") == true || e.host?.contains("docker") == true
            e.kind = flows[i].ttl <= 0 ? .closed : .bytes
            e.bytesIn = UInt64.random(in: 2_000...(heavy ? 2_400_000 : 180_000))
            e.bytesOut = UInt64.random(in: 400...(heavy ? 60_000 : 24_000))
            e.date = date
            events.append(e)
            if flows[i].ttl <= 0 { flows.remove(at: i) }
        }
        store.ingest(events)
    }

    private static func weighted() -> App {
        var n = Int.random(in: 0..<apps.reduce(0) { $0 + $1.weight })
        for a in apps { n -= a.weight; if n < 0 { return a } }
        return apps[0]
    }
}
