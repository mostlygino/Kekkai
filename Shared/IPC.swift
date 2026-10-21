import Foundation

// App <-> extension messages travel as JSON `Data` over XPC, so both sides share these Codable types.

/// Implemented by the extension, called by the app.
@objc protocol ProviderXPC {
    /// Registers the caller for events and returns the current `RuleSet`.
    func register(reply: @escaping (Data) -> Void)
    func setRules(_ rules: Data)
    /// Answer for every flow waiting on `appKey`. `remember` stores an app rule.
    func decide(appKey: String, allow: Bool, remember: Bool)
}

/// Implemented by the app, called by the extension.
@objc protocol AppXPC {
    /// `[FlowEvent]`
    func flowEvents(_ events: Data)
    /// `[ApprovalRequest]`: the full list of apps waiting for an answer.
    func approvals(_ requests: Data)
}

struct FlowEvent: Codable {
    enum Kind: String, Codable { case opened, bytes, closed }
    var kind: Kind
    var flowID: UUID
    var app: AppIdentity
    var host: String?
    var ip: String
    var port: String
    var proto: String
    var inbound: Bool
    var verdict: Verdict
    /// Why the verdict was reached, when a rule or mode decided it.
    var reason: String?
    /// Activity list only: how many identical connections this row stands for (nil means one).
    var repeats: Int?
    /// Bytes since the previous event for this flow.
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var date = Date()
}

struct ApprovalRequest: Codable, Identifiable, Hashable {
    var app: AppIdentity
    var hosts: [String]
    var ips: [String]
    var ports: [String]
    var count: Int
    var since: Date
    var id: String { app.key }
}

enum IPC {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    /// Signing requirement for a peer: same team, given bundle identifier. Empty team never matches.
    static func requirement(identifier: String, team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    static var teamID: String { Bundle.main.object(forInfoDictionaryKey: "KekkaiTeamID") as? String ?? "" }
    static let appBundleID = "com.mostlygino.Kekkai"
    static let extensionBundleID = "com.mostlygino.Kekkai.Filter"
}
