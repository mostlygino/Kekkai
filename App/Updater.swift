import AppKit

/// Installs new Kekkai releases from GitHub, the same way Shīru does. With the `gh` CLI installed it goes through
/// gh and its login (which also works for a private fork); without it, through GitHub's public API over HTTPS.
/// Either way the app stores no token. A release is installed only when its zip
/// carries a good signature by the release key bundled in the app, and the app inside says it is that version.
@MainActor
final class Updater {
    static let shared = Updater()

    private static let repo = "mostlygino/Kekkai"
    /// Gino de Graaff's release key; scripts/release.sh signs with the same one.
    private static let releaseKey = "4C49B6E8DC9F50C80A1A20B805BE68B6158B9E08"
    /// GUI apps do not inherit the shell PATH.
    private static let ghPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
    /// The signature check uses Homebrew's gpg only.
    private static let gpgPaths = ["/opt/homebrew/bin/gpg", "/usr/local/bin/gpg"]
    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private var isBusy = false

    enum UpdateError: LocalizedError {
        case missingTool(String)
        case tool(String, String)
        case badRelease(String)

        var errorDescription: String? {
            switch self {
            case .missingTool(let name): "Updates need \(name). Install it with “brew install gnupg”."
            case .tool(let name, let message): "\(name) failed: \(message)"
            case .badRelease(let reason): "The update was refused: \(reason) Nothing was installed."
            }
        }
    }

    /// Once a day at most, quietly; only a newer release shows anything.
    func checkInBackground() {
        guard !Demo.isOn else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.checkInterval else { return }
        Task { await check(interactive: false) }
    }

    /// "Check for Updates…": also reports "up to date" and errors.
    func check(interactive: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let gh = try? Self.locate(Self.ghPaths, name: "gh")
            let tag = try await Self.latestTag(gh)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            let current = BuildInfo.current.version
            guard let latest = Self.version(fromTag: tag), let installed = Version(current), installed < latest else {
                if interactive { Self.alert("Kekkai is up to date.", "You have version \(current).") }
                return
            }
            guard Self.ask(version: latest.description, current: current) else { return }
            try await install(tag: tag, version: latest.description, gh: gh)
        } catch {
            if interactive { Self.alert("Couldn't update Kekkai.", error.localizedDescription) }
        }
    }

    /// Tag of the newest published release, betas (pre-releases) included, or "" when there is none yet.
    private static func latestTag(_ gh: URL?) async throws -> String {
        guard let gh else {
            struct Release: Decodable { let tag_name: String; let draft: Bool }
            let (data, response) = try await URLSession.shared.data(from: api("releases?per_page=20"))
            if (response as? HTTPURLResponse)?.statusCode == 404 { return "" }
            try ensureOK(response, "GitHub")
            return try JSONDecoder().decode([Release].self, from: data).first { !$0.draft }?.tag_name ?? ""
        }
        let result = try await run(gh, ["api", "repos/\(repo)/releases?per_page=20",
                                        "--jq", "[.[] | select(.draft | not)][0].tag_name // \"\""], name: "GitHub", allowFailure: true)
        if result.code != 0 {
            if result.stderr.contains("HTTP 404") { return "" }
            throw UpdateError.tool("GitHub", result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only plain tags like v1.2.3: the tag ends up in a file name and a gh argument.
    static func version(fromTag tag: String) -> Version? {
        guard tag.wholeMatch(of: /v\d{1,4}(\.\d{1,4}){1,3}/) != nil else { return nil }
        return Version(String(tag.dropFirst()))
    }

    private func install(tag: String, version: String, gh: URL?) async throws {
        let target = Bundle.main.bundleURL
        guard !target.path.contains("/DerivedData/"), !target.path.contains("/AppTranslocation/"), !target.path.contains("/build/") else {
            throw UpdateError.badRelease("this copy doesn't run from its install folder. Copy Kekkai to Applications first.")
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError.badRelease("Kekkai can't write to \(target.deletingLastPathComponent().path).")
        }
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: target, create: true)
        do {
            let app = try await download(tag: tag, version: version, gh: gh, into: work)
            try Self.launchInstaller(newApp: app, target: target, work: work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
        Store.shared.saveHistory()
        NSApp.terminate(nil)
    }

    /// Downloads, verifies and unpacks the release. Returns the checked Kekkai.app.
    private func download(tag: String, version: String, gh: URL?, into work: URL) async throws -> URL {
        let zipName = "Kekkai-\(version).zip"
        if let gh {
            _ = try await Self.run(gh, ["release", "download", tag, "--repo", Self.repo,
                                        "--pattern", zipName, "--pattern", zipName + ".sig", "--dir", work.path], name: "Download")
        } else {
            try await Self.downloadAssets([zipName, zipName + ".sig"], tag: tag, into: work)
        }
        let zip = work.appendingPathComponent(zipName)
        try await Self.verifySignature(file: zip, signature: work.appendingPathComponent(zipName + ".sig"))

        let unpacked = work.appendingPathComponent("unpacked")
        _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, unpacked.path], name: "Unzip")
        let app = unpacked.appendingPathComponent("Kekkai.app")
        let entries = try FileManager.default.contentsOfDirectory(atPath: unpacked.path)
        let kind = try app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard entries == ["Kekkai.app"], kind.isDirectory == true, kind.isSymbolicLink == false else {
            throw UpdateError.badRelease("the download doesn't hold just Kekkai.app.")
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        // The tag is only trusted once the signed bundle says the same: this stops an old, validly signed
        // zip being offered again under a newer tag.
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError.badRelease("the app in the download isn't Kekkai \(version).")
        }
        _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-cr", app.path], name: "xattr")
        _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path], name: "Code signature check")
        return app
    }

    /// Good signature over `file` by the pinned release key, checked in a throwaway keyring so the user's own
    /// keys and trust settings play no part.
    static func verifySignature(file: URL, signature: URL) async throws {
        let gpg = try locate(gpgPaths, name: "GnuPG")
        guard let keyURL = Bundle.main.url(forResource: "release-key", withExtension: "asc") else {
            throw UpdateError.badRelease("the release key is missing from this copy of Kekkai.")
        }
        // Short path: gpg puts agent sockets in its home directory.
        let home = URL(fileURLWithPath: "/tmp/kekkai-release-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            let conf = gpg.deletingLastPathComponent().appendingPathComponent("gpgconf")
            _ = try? Process.run(conf, arguments: ["--homedir", home.path, "--kill", "all"]).waitUntilExit()
            try? FileManager.default.removeItem(at: home)
        }
        _ = try await run(gpg, ["--homedir", home.path, "--batch", "--import", keyURL.path], name: "GnuPG import")
        let result = try await run(gpg, ["--homedir", home.path, "--batch", "--no-auto-key-retrieve", "--status-fd", "1",
                                         "--verify", "--", signature.path, file.path], name: "GnuPG", allowFailure: true)
        guard result.code == 0, goodSignature(status: result.stdout, fingerprint: releaseKey) else {
            throw UpdateError.badRelease("it isn't signed by the Kekkai release key.")
        }
    }

    /// True when gpg's status output has a VALIDSIG whose primary key is `fingerprint`.
    nonisolated static func goodSignature(status: String, fingerprint: String) -> Bool {
        status.split(separator: "\n").contains { line in
            let f = line.split(separator: " ")
            // [GNUPG:] VALIDSIG <sig fpr> <date> <ts> <exp> <ver> <res> <pk algo> <hash> <class> <primary fpr>
            return f.count >= 12 && f[0] == "[GNUPG:]" && f[1] == "VALIDSIG" && f[11].uppercased() == fingerprint.uppercased()
        }
    }

    /// Swaps the bundle by rename once this process has quit, then opens Kekkai again. A failed swap puts the
    /// old copy back. Paths go in as arguments; nothing from GitHub is written into the script.
    private static func launchInstaller(newApp: URL, target: URL, work: URL) throws {
        let script = """
        i=0
        while kill -0 "$1" 2>/dev/null; do
          i=$((i + 1)); [ "$i" -gt 300 ] && { rm -rf "$4"; exit 1; }
          sleep 0.2
        done
        if mv "$3" "$4/old" && mv "$2" "$3"; then
          /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$3"
          rm -rf "$4"
        else
          [ -e "$3" ] || mv "$4/old" "$3"
        fi
        /usr/bin/open "$3"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "kekkai-update",
                             String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path, work.path]
        try process.run()
    }

    // MARK: GitHub over HTTPS (no gh)

    private static func api(_ path: String) -> URL { URL(string: "https://api.github.com/repos/\(repo)/\(path)")! }

    private static func ensureOK(_ response: URLResponse, _ what: String) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.tool(what, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
    }

    /// Downloads release assets by name. The signature check after this is what makes them trustworthy;
    /// HTTPS only keeps the download private and intact.
    private static func downloadAssets(_ names: [String], tag: String, into dir: URL) async throws {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Release: Decodable { let assets: [Asset] }
        let (data, response) = try await URLSession.shared.data(from: api("releases/tags/\(tag)"))
        try ensureOK(response, "GitHub")
        let assets = try JSONDecoder().decode(Release.self, from: data).assets
        for name in names {
            guard let asset = assets.first(where: { $0.name == name }), asset.browser_download_url.scheme == "https" else {
                throw UpdateError.badRelease("the release has no \(name).")
            }
            let (file, reply) = try await URLSession.shared.download(from: asset.browser_download_url)
            try ensureOK(reply, "Download")
            try FileManager.default.moveItem(at: file, to: dir.appendingPathComponent(name))
        }
    }

    private static func locate(_ paths: [String], name: String) throws -> URL {
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else { throw UpdateError.missingTool(name) }
        return URL(fileURLWithPath: path)
    }

    @discardableResult
    private static func run(_ tool: URL, _ arguments: [String], name: String,
                            allowFailure: Bool = false) async throws -> (code: Int32, stdout: String, stderr: String) {
        let result: (Int32, String, String) = try await Task.detached {
            let p = Process()
            p.executableURL = tool
            p.arguments = arguments
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
        }.value
        if result.0 != 0, !allowFailure {
            throw UpdateError.tool(name, result.2.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (result.0, result.1, result.2.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func ask(version: String, current: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Kekkai \(version) is available."
        alert.informativeText = "You have \(current). Kekkai quits, installs the update and opens again. The filter keeps running in the meantime."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

/// Dotted version numbers, compared numerically ("0.10.0" > "0.9.2").
struct Version: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        let p = text.split(separator: ".").map { Int($0) }
        guard !p.isEmpty, p.count <= 4, p.allSatisfy({ $0 != nil }) else { return nil }
        parts = p.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}
