import Foundation

/// XPC listener in the extension. Only the Kekkai app signed by the same team may connect:
/// any process that could talk to this service could otherwise rewrite the firewall rules.
final class IPCServer: NSObject, NSXPCListenerDelegate, ProviderXPC {
    static let shared = IPCServer()

    weak var provider: FilterDataProvider?
    private var listener: NSXPCListener?
    private let lock = NSLock()
    private var client: NSXPCConnection?

    func start() {
        guard let ne = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
              let name = ne["NEMachServiceName"] as? String else {
            log.fault("NEMachServiceName missing from Info.plist")
            return
        }
        let listener = NSXPCListener(machServiceName: name)
        listener.delegate = self
        listener.resume()
        self.listener = listener
    }

    var hasClient: Bool { lock.withLock { client != nil } }

    private var app: AppXPC? {
        lock.withLock { client?.remoteObjectProxyWithErrorHandler { _ in } as? AppXPC }
    }

    func send(events: [FlowEvent]) {
        guard let app, let data = try? IPC.encoder.encode(events) else { return }
        app.flowEvents(data)
    }

    func send(approvals: [ApprovalRequest]) {
        guard let app, let data = try? IPC.encoder.encode(approvals) else { return }
        app.approvals(data)
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let team = IPC.teamID
        guard !team.isEmpty else {
            log.error("no team ID in Info.plist; refusing XPC client")
            return false
        }
        connection.setCodeSigningRequirement(IPC.requirement(identifier: IPC.appBundleID, team: team))
        connection.exportedInterface = NSXPCInterface(with: ProviderXPC.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: AppXPC.self)
        let gone = { [weak self, weak connection] in
            guard let self else { return }
            self.lock.withLock { if self.client === connection { self.client = nil } }
        }
        connection.invalidationHandler = gone
        connection.interruptionHandler = gone
        connection.resume()
        return true
    }

    // MARK: ProviderXPC

    func register(reply: @escaping (Data) -> Void) {
        lock.withLock { client = NSXPCConnection.current() }
        reply((try? IPC.encoder.encode(RuleStore.shared.rules)) ?? Data())
        provider?.resendApprovals()
    }

    func setRules(_ rules: Data) {
        guard let new = try? IPC.decoder.decode(RuleSet.self, from: rules) else {
            log.error("setRules: undecodable payload ignored")
            return
        }
        RuleStore.shared.update { $0 = new }
    }

    func decide(appKey: String, allow: Bool, remember: Bool) {
        if remember { RuleStore.shared.update { $0.apps[appKey] = allow } }
        provider?.resolve(appKey: appKey, allow: allow)
    }
}
