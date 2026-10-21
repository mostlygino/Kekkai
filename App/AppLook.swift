import AppKit
import SwiftUI

/// How a process is shown: a name people recognise and the icon of the app it belongs to.
///
/// Order of resolution:
/// 1. Inside an app bundle (helpers, agents, XPC services): the outermost app's icon, "App (Helper)" as name.
/// 2. A known macOS service: a plain-language name ("Push notifications") and, where one exists, the icon of
///    the app it serves (Safari for WebKit networking, App Store for appstored); otherwise the system tile.
/// 3. A bundle ID whose parent is an installed app (system extensions, launch agents): that app's name and icon.
/// 4. A command-line tool on disk: its name with a terminal tile.
/// 5. Anything else: a monogram tile.
enum AppLook {
    struct Look {
        let title: String
        /// The process's own name when the title is a friendlier one, for the subtitle and tooltips.
        let process: String?
        let icon: NSImage
    }

    // Read from table sort comparators as well as views, so not tied to the main actor; a lock guards the cache.
    nonisolated(unsafe) private static var cache: [String: Look] = [:]
    private static let lock = NSLock()

    static func look(for app: AppIdentity) -> Look {
        let key = app.key + "|" + app.path
        if let hit = lock.withLock({ cache[key] }) { return hit }
        let look = resolve(app)
        lock.withLock {
            if cache.count > 2000 { cache.removeAll() }
            cache[key] = look
        }
        return look
    }

    private static func resolve(_ app: AppIdentity) -> Look {
        let process = processName(app.path)
        let fm = FileManager.default

        // 1. Inside an app bundle.
        if let outer = outermostApp(app.path), fm.fileExists(atPath: outer) {
            return Look(title: app.displayName, process: nil, icon: NSWorkspace.shared.icon(forFile: outer))
        }

        // 2. macOS services.
        if app.isApple || app.path.hasPrefix("/System/") || app.path.hasPrefix("/usr/") {
            if let known = services[process] ?? app.signingID.flatMap({ services[$0] }) {
                let icon = known.app.flatMap(appIcon(atPath:)) ?? Tile.system
                return Look(title: known.title, process: process, icon: icon)
            }
        }

        // 3. Bundles that live outside their app (system extensions, app extensions, XPC services, launch agents):
        //    the app their bundle ID belongs to. Plain command-line tools skip this: a signing ID like
        //    "com.anthropic.claude-code" can match an unrelated helper app and borrow its name.
        let detached = [".systemextension", ".appex", ".xpc", "/LaunchAgents/", "/LaunchDaemons/"].contains { app.path.contains($0) }
        if detached, let id = app.signingID, let host = hostApp(forBundleID: id) {
            let name = fm.displayName(atPath: host.path).replacingOccurrences(of: ".app", with: "")
            return Look(title: "\(name) · \(friendly(process))", process: process, icon: NSWorkspace.shared.icon(forFile: host.path))
        }

        // 4. Command-line tools.
        if fm.fileExists(atPath: app.path) {
            return Look(title: app.displayName, process: nil, icon: app.isApple ? Tile.system : Tile.terminal)
        }
        // A bare name means the process ended before Kekkai could read its path.
        if !app.path.contains("/") {
            return Look(title: app.path, process: nil, icon: Tile.terminal)
        }

        // 5. Gone from disk (or on another Mac).
        return Look(title: app.displayName, process: nil, icon: Monogram.image(for: app.displayName))
    }

    /// "/…/Contents/MacOS/Foo" or "/…/foo.xpc" -> "Foo" / "foo".
    static func processName(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent
        for ext in [".app", ".xpc", ".appex", ".systemextension", ".framework"] where name.hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        return name
    }

    private static func outermostApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// "io.tailscale.ipn.macsys.network-extension" -> the app "io.tailscale.ipn.macsys", if installed.
    private static func hostApp(forBundleID id: String) -> URL? {
        var parts = id.split(separator: ".")
        while parts.count >= 2 {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")),
               url.path.hasSuffix(".app"), !url.path.hasPrefix("/System/Library/") {
                return url
            }
            parts.removeLast()
        }
        return nil
    }

    private static func appIcon(atPath path: String) -> NSImage? {
        FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
    }

    /// "io.tailscale.ipn.macsys.network-extension" -> "network extension".
    private static func friendly(_ process: String) -> String {
        let last = process.split(separator: ".").last.map(String.init) ?? process
        return last.replacingOccurrences(of: "-", with: " ")
    }

    /// macOS services seen on most Macs, in plain language. Keyed by process name or signing ID.
    private static let services: [String: (title: String, app: String?)] = [
        "mDNSResponder": ("DNS lookups", nil),
        "apsd": ("Push notifications", nil),
        "trustd": ("Certificate checks", nil),
        "nsurlsessiond": ("Background downloads", nil),
        "syspolicyd": ("Gatekeeper", nil),
        "cloudd": ("iCloud", nil),
        "bird": ("iCloud Drive", "/System/Library/CoreServices/Finder.app"),
        "appstored": ("App Store", "/System/Applications/App Store.app"),
        "softwareupdated": ("Software Update", "/System/Applications/System Settings.app"),
        "mobileassetd": ("System downloads", nil),
        "mdmclient": ("Device management", "/System/Applications/System Settings.app"),
        "swcd": ("Shared web credentials", nil),
        "dataaccessd": ("Calendars and contacts", "/System/Applications/Calendar.app"),
        "cloudtelemetryd": ("iCloud diagnostics", nil),
        "identityservicesd": ("Messages and FaceTime", "/System/Applications/Messages.app"),
        "imagent": ("Messages", "/System/Applications/Messages.app"),
        "geod": ("Maps and location", "/System/Applications/Maps.app"),
        "com.apple.geod": ("Maps and location", "/System/Applications/Maps.app"),
        "locationd": ("Location Services", "/System/Applications/Maps.app"),
        "com.apple.WebKit.Networking": ("Safari and web views", "/Applications/Safari.app"),
        "com.apple.Safari.SafeBrowsing": ("Safe Browsing", "/Applications/Safari.app"),
        "com.apple.Safari.SafeBrowsing.Service": ("Safe Browsing", "/Applications/Safari.app"),
        "parsecd": ("Spotlight suggestions", nil),
        "assistantd": ("Siri", nil),
        "akd": ("Apple Account", "/System/Applications/System Settings.app"),
        "accountsd": ("Internet accounts", "/System/Applications/System Settings.app"),
        "timed": ("Network time", nil),
        "rapportd": ("Nearby devices", nil),
        "sharingd": ("AirDrop and sharing", "/System/Library/CoreServices/Finder.app"),
        "photolibraryd": ("Photos library", "/System/Applications/Photos.app"),
        "commerce": ("Purchases", "/System/Applications/App Store.app"),
        "storedownloadd": ("App Store downloads", "/System/Applications/App Store.app"),
        "ckdiscretionaryd": ("iCloud sync", nil),
        "remindd": ("Reminders", "/System/Applications/Reminders.app"),
        "nehelper": ("Network extensions", nil),
        "networkserviceproxy": ("iCloud Private Relay", nil),
        "netbiosd": ("Local network names", nil),
        "curl": ("curl", nil),
    ]

    /// Flat tiles in the theme's neutrals: one for macOS internals, one for command-line tools.
    enum Tile {
        static let system = make(symbol: "gearshape.2.fill", top: 0x6E6A70, bottom: 0x4A474D)
        static let terminal = make(symbol: "apple.terminal.fill", top: 0x3A3740, bottom: 0x24222A)

        private static func make(symbol: String, top: UInt32, bottom: UInt32) -> NSImage {
            func color(_ h: UInt32) -> NSColor {
                NSColor(srgbRed: CGFloat(h >> 16 & 0xff) / 255, green: CGFloat(h >> 8 & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: 1)
            }
            return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 14, yRadius: 14)
                NSGradient(starting: color(top), ending: color(bottom))?.draw(in: tile, angle: -90)
                NSColor.white.withAlphaComponent(0.14).setStroke()
                tile.lineWidth = 1
                tile.stroke()
                let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .medium)
                    .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.92)]))
                if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let s = glyph.size
                    glyph.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
                }
                return true
            }
        }
    }
}

extension AppIdentity {
    /// The name to show: friendly for macOS services and extensions, see `AppLook`.
    var title: String { AppLook.look(for: self).title }
    /// The real process name when `title` is a friendlier one.
    var processName: String? { AppLook.look(for: self).process }
    var icon: NSImage { AppLook.look(for: self).icon }
}
