import Foundation
import Security

/// What a binary's code signature says, read on demand for the inspector and the approval panel.
struct SignatureInfo {
    enum Status { case valid, unsigned, missing, invalid(String) }
    var status: Status
    var identifier: String?
    var teamID: String?
    /// Leaf first, e.g. "Developer ID Application: Example Ltd (TEAM)", "Developer ID Certification Authority", "Apple Root CA".
    var chain: [String] = []
    var isApple = false
    var notarized = false
    var hardenedRuntime = false
    var signedAt: Date?

    var title: String {
        switch status {
        case .unsigned: "Not signed"
        case .missing: "Not on this Mac"
        case .invalid: "Signature invalid"
        case .valid:
            if isApple { "Signed by Apple" }
            else if teamID != nil { notarized ? "Developer ID, notarised" : "Developer ID" }
            else { "Ad-hoc signature" }
        }
    }

    var trustworthy: Bool {
        if case .valid = status { return isApple || teamID != nil }
        return false
    }

    static func read(path: String) -> SignatureInfo {
        guard FileManager.default.fileExists(atPath: path) else { return SignatureInfo(status: .missing) }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return SignatureInfo(status: .invalid("The file could not be read."))
        }
        var info = SignatureInfo(status: .valid)
        let check = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        if check == errSecCSUnsigned { return SignatureInfo(status: .unsigned) }
        if check != errSecSuccess {
            info.status = .invalid((SecCopyErrorMessageString(check, nil) as String?) ?? "Error \(check)")
        }

        var dict: CFDictionary?
        if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dict) == errSecSuccess,
           let d = dict as? [String: Any] {
            info.identifier = d[kSecCodeInfoIdentifier as String] as? String
            info.teamID = d[kSecCodeInfoTeamIdentifier as String] as? String
            info.signedAt = d[kSecCodeInfoTimestamp as String] as? Date ?? d[kSecCodeInfoTime as String] as? Date
            if let certs = d[kSecCodeInfoCertificates as String] as? [SecCertificate] {
                info.chain = certs.compactMap { SecCertificateCopySubjectSummary($0) as String? }
            }
            if let flags = d[kSecCodeInfoFlags as String] as? UInt32 { info.hardenedRuntime = flags & 0x10000 != 0 }
        }
        func satisfies(_ requirement: String) -> Bool {
            var req: SecRequirement?
            guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
            return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
        }
        info.isApple = satisfies("anchor apple")
        info.notarized = !info.isApple && satisfies("notarized")
        if info.teamID != nil, !info.isApple, !satisfies("anchor apple generic") { info.teamID = nil }  // self-signed team claims do not count
        return info
    }
}

/// The developer's own description of what an app connects to and why (Internet Access Policy, used by
/// Little Snitch and others). Lives in the app bundle as InternetAccessPolicy.plist or .json.
struct AccessPolicy {
    struct Connection: Identifiable {
        let id = UUID()
        var host: String
        var port: String?
        var incoming: Bool
        var purpose: String?
        var denyConsequences: String?
    }

    var summary: String?
    var connections: [Connection]

    static func read(appPath: String) -> AccessPolicy? {
        guard let bundle = bundleRoot(appPath) else { return nil }
        let res = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Resources")
        var raw: [String: Any]?
        for name in ["InternetAccessPolicy.plist", "InternetAccessPolicy.json"] {
            let url = res.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), data.count < 1_000_000 else { continue }
            raw = name.hasSuffix(".plist")
                ? try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                : try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if raw != nil { break }
        }
        guard let raw else { return nil }
        let list = (raw["Connections"] as? [[String: Any]] ?? []).prefix(100).compactMap { c -> Connection? in
            guard let host = c["Host"] as? String else { return nil }
            let port = (c["Port"] as? String) ?? (c["Port"] as? Int).map(String.init)
            return Connection(host: host, port: port, incoming: c["IsIncoming"] as? Bool ?? false,
                              purpose: c["Purpose"] as? String, denyConsequences: c["DenyConsequences"] as? String)
        }
        return AccessPolicy(summary: raw["ApplicationDescription"] as? String, connections: Array(list))
    }

    /// "/Applications/X.app/Contents/MacOS/X" -> "/Applications/X.app"
    private static func bundleRoot(_ path: String) -> String? {
        guard let r = path.range(of: ".app", options: .backwards) else { return nil }
        return String(path[..<r.upperBound])
    }
}

extension SignatureInfo {
    /// Who signed a binary, without hashing its resources: enough to name and group a process, and cheap
    /// enough for every new process Watch mode sees. The inspector still runs the full `read(path:)`.
    static func quickIdentity(path: String) -> (identifier: String?, teamID: String?, isApple: Bool) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return (nil, nil, false)
        }
        var dict: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dict) == errSecSuccess,
              let d = dict as? [String: Any] else { return (nil, nil, false) }
        let light = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        func satisfies(_ requirement: String) -> Bool {
            var req: SecRequirement?
            guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
            return SecStaticCodeCheckValidity(code, light, req) == errSecSuccess
        }
        let apple = satisfies("anchor apple")
        let team = !apple && satisfies("anchor apple generic") ? d[kSecCodeInfoTeamIdentifier as String] as? String : nil
        return (d[kSecCodeInfoIdentifier as String] as? String, team, apple)
    }
}
