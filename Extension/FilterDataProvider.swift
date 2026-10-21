import Foundation
import Network
import NetworkExtension
import Security

final class FilterDataProvider: NEFilterDataProvider {
    /// How many outbound bytes to read looking for a TLS server name.
    private static let sniPeek = 4096

    private let q = DispatchQueue(label: "com.mostlygino.Kekkai.filter")
    // Everything below is only touched on `q`.
    private var identities: [Data: AppIdentity] = [:]
    private var live: [UUID: FlowEvent] = [:]
    private var lastBytes: [UUID: (in: UInt64, out: UInt64)] = [:]
    private var pending: [String: (request: ApprovalRequest, flows: [(flow: NEFilterFlow, event: FlowEvent, at: Date)])] = [:]
    private var outbox: [FlowEvent] = []
    /// First outbound bytes per flow while looking for the TLS server name.
    private var sniBuffers: [UUID: [UInt8]] = [:]
    /// Address to the name it was looked up by, learned from DNS answers. Names connections that carry no hostname.
    private var dnsNames: [String: String] = [:]
    /// DNS flows we read answers from.
    private var dnsFlows: Set<UUID> = []
    private var flushTimer: DispatchSourceTimer?

    private static let appleRequirement: SecRequirement? = {
        var r: SecRequirement?
        return SecRequirementCreateWithString("anchor apple" as CFString, [], &r) == errSecSuccess ? r : nil
    }()
    private static let developerRequirement: SecRequirement? = {
        var r: SecRequirement?
        return SecRequirementCreateWithString("anchor apple generic" as CFString, [], &r) == errSecSuccess ? r : nil
    }()

    // MARK: Lifecycle

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        IPCServer.shared.provider = self
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        flushTimer = timer
        // Every socket flow, both directions, comes to handleNewFlow.
        apply(NEFilterSettings(rules: [], defaultAction: .filterData)) { error in
            if let error { log.error("apply settings failed: \(error.localizedDescription, privacy: .public)") }
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        flushTimer?.cancel()
        flushTimer = nil
        completionHandler()
    }

    // MARK: Flows

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socket = flow as? NEFilterSocketFlow,
              let endpoint = socket.remoteFlowEndpoint,
              case let .hostPort(remote, port) = endpoint else { return .allow() }

        var host = socket.remoteHostname
        let ip: String
        let loopback: Bool
        switch remote {
        case .ipv4(let a): ip = "\(a)"; loopback = a.isLoopback
        case .ipv6(let a): ip = "\(a)"; loopback = a.isLoopback
        case .name(let n, _): ip = n; loopback = n == "localhost"; host = host ?? n
        @unknown default: ip = "\(remote)"; loopback = false
        }

        let tcp = socket.socketProtocol == IPPROTO_TCP
        let inbound = flow.direction == .inbound
        let app = q.sync { identity(for: flow.sourceAppAuditToken) }
        if host == nil { host = q.sync { dnsNames[ip] } }
        let rules = RuleStore.shared.rules
        var event = FlowEvent(kind: .opened, flowID: flow.identifier, app: app, host: host?.lowercased(),
                              ip: ip, port: "\(port.rawValue)", proto: tcp ? "TCP" : "UDP",
                              inbound: inbound, verdict: .allow)
        let quic = !tcp && !inbound && port.rawValue == 443
        let dns = !tcp && !inbound && port.rawValue == 53
        let decision = rules.decide(app: app.key, isApple: app.isApple, host: host, ip: ip, loopback: loopback,
                                    quic: quic, dns: dns, appOpen: IPCServer.shared.hasClient)
        event.reason = decision.reason

        switch decision.verdict {
        case .block:
            event.verdict = .block
            q.async { self.outbox.append(event) }
            return .drop()
        case .ask:
            // The app went away between the decision and now: same rule as when it was never open.
            guard IPCServer.shared.hasClient else {
                event.verdict = rules.failClosedWithoutApp ? .block : .allow
                event.reason = rules.failClosedWithoutApp ? "Kekkai was not open to ask" : "Kekkai was not open; Block List only"
                q.async { event.verdict == .block ? self.outbox.append(event) : self.track(event) }
                return event.verdict == .block ? .drop() : allowVerdict(peek: host == nil && tcp && !inbound)
            }
            event.verdict = .ask
            q.sync { hold(flow, event: event, timeout: TimeInterval(rules.approvalTimeout)) }
            return .pause()
        case .allow:
            q.async { self.track(event) }
            if dns {
                // Read the answers coming back, so later connections to those addresses get a name.
                q.async { self.dnsFlows.insert(flow.identifier) }
                let v = NEFilterNewFlowVerdict.filterDataVerdict(withFilterInbound: true, peekInboundBytes: 1500,
                                                                 filterOutbound: false, peekOutboundBytes: 0)
                v.shouldReport = true
                return v
            }
            return allowVerdict(peek: host == nil && tcp && !inbound && !loopback)
        }
    }

    /// Allow, optionally reading the first outbound bytes to learn the TLS server name.
    /// ponytail: TLS over TCP only. QUIC without a hostname is dropped by rule instead (see `RuleSet.blockUnknownQUIC`);
    /// ECH hides the real name behind a public one.
    private func allowVerdict(peek: Bool) -> NEFilterNewFlowVerdict {
        let verdict: NEFilterNewFlowVerdict = peek
            ? .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0,
                                 filterOutbound: true, peekOutboundBytes: Self.sniPeek)
            : .allow()
        verdict.shouldReport = true
        verdict.statisticsReportFrequency = .medium
        return verdict
    }

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict {
        let id = flow.identifier
        // Works whether the system re-delivers everything from offset 0 or only the new bytes at the end.
        let bytes: [UInt8]? = q.sync {
            let joined = joinPeek(sniBuffers[id] ?? [], offset: offset, [UInt8](readBytes))
            sniBuffers[id] = joined
            return joined
        }
        guard let bytes else { q.async { self.sniBuffers[id] = nil }; return .allow() }

        switch parseSNI(bytes) {
        case .needMore(let total) where total > bytes.count:
            return NEFilterDataVerdict(passBytes: 0, peekBytes: total)
        case .host(let name):
            let rule = RuleStore.shared.rules.blockingRule(host: name)
            q.async {
                self.sniBuffers[id] = nil
                guard var event = self.live[id] else { return }
                event.host = name
                event.verdict = rule == nil ? .allow : .block
                event.reason = rule.map { "Block List: \($0)" } ?? event.reason
                self.outbox.append(event)
                if rule != nil { self.forget(id) } else { self.live[id] = event }
            }
            return rule == nil ? .allow() : .drop()
        default:
            q.async { self.sniBuffers[id] = nil }
            return .allow()
        }
    }

    /// DNS answers only. Each UDP datagram is one message; we read it and let it through unchanged.
    /// ponytail: classic DNS over UDP 53. DNS over HTTPS and TLS are covered by the TLS server name instead.
    override func handleInboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict {
        let answers = parseDNSAnswers([UInt8](readBytes))
        if !answers.isEmpty {
            q.async {
                if self.dnsNames.count > 20_000 { self.dnsNames.removeAll(keepingCapacity: true) }
                for a in answers { self.dnsNames[a.ip] = a.name }
            }
        }
        // Keep reading this flow's later answers.
        return NEFilterDataVerdict(passBytes: readBytes.count, peekBytes: 1500)
    }

    override func handle(_ report: NEFilterReport) {
        guard report.event == .statistics || report.event == .flowClosed, let flow = report.flow else { return }
        let id = flow.identifier
        // ponytail: treats report byte counts as running totals per flow; if they turn out to be deltas, drop the subtraction.
        let total = (in: UInt64(max(0, report.bytesInboundCount)), out: UInt64(max(0, report.bytesOutboundCount)))
        q.async {
            guard var event = self.live[id] else { return }
            let last = self.lastBytes[id] ?? (0, 0)
            event.kind = report.event == .flowClosed ? .closed : .bytes
            event.bytesIn = total.in > last.in ? total.in - last.in : 0
            event.bytesOut = total.out > last.out ? total.out - last.out : 0
            event.date = Date()
            self.outbox.append(event)
            if report.event == .flowClosed { self.forget(id) } else { self.lastBytes[id] = total }
        }
    }

    // MARK: Approval

    /// On `q`.
    private func hold(_ flow: NEFilterFlow, event: FlowEvent, timeout: TimeInterval) {
        let key = event.app.key
        var entry = pending[key] ?? (ApprovalRequest(app: event.app, hosts: [], ips: [], ports: [], count: 0, since: Date()), [])
        entry.flows.append((flow, event, Date()))
        entry.request.count += 1
        func add(_ v: String?, to list: inout [String]) {
            if let v, !list.contains(v), list.count < 50 { list.append(v) }
        }
        add(event.host, to: &entry.request.hosts)
        add(event.ip, to: &entry.request.ips)
        add(event.port, to: &entry.request.ports)
        pending[key] = entry
        outbox.append(event)
        IPCServer.shared.send(approvals: pending.values.map(\.request))

        q.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.expire(key, after: timeout) }
    }

    /// On `q`. Drops flows for `key` that have waited past the timeout.
    private func expire(_ key: String, after timeout: TimeInterval) {
        guard var entry = pending[key] else { return }
        let cutoff = Date().addingTimeInterval(-timeout + 1)
        let stale = entry.flows.filter { $0.at <= cutoff }
        guard !stale.isEmpty else { return }
        for item in stale {
            resumeFlow(item.flow, with: NEFilterNewFlowVerdict.drop())
            var e = item.event; e.verdict = .block; e.reason = "No answer in time"; outbox.append(e)
        }
        entry.flows.removeAll { $0.at <= cutoff }
        pending[key] = entry.flows.isEmpty ? nil : entry
        IPCServer.shared.send(approvals: pending.values.map(\.request))
    }

    /// The app answered for every flow waiting on `appKey`.
    func resolve(appKey: String, allow: Bool) {
        q.async {
            guard let entry = self.pending.removeValue(forKey: appKey) else { return }
            for item in entry.flows {
                var e = item.event
                e.verdict = allow ? .allow : .block
                e.reason = allow ? "Allowed by you" : "Blocked by you"
                let peek = e.host == nil && e.proto == "TCP" && !e.inbound
                self.resumeFlow(item.flow, with: allow ? self.allowVerdict(peek: peek) : NEFilterNewFlowVerdict.drop())
                self.outbox.append(e)
                if allow { self.live[e.flowID] = e }
            }
            IPCServer.shared.send(approvals: self.pending.values.map(\.request))
        }
    }

    func resendApprovals() {
        q.async { IPCServer.shared.send(approvals: self.pending.values.map(\.request)) }
    }

    // MARK: Helpers (on `q`)

    private func track(_ event: FlowEvent) {
        // ponytail: hard cap in case close reports go missing; a sweep by age if this ever trips in practice.
        if live.count > 20_000 { live.removeAll(); lastBytes.removeAll(); sniBuffers.removeAll() }
        live[event.flowID] = event
        outbox.append(event)
    }

    private func forget(_ id: UUID) {
        live[id] = nil
        lastBytes[id] = nil
        sniBuffers[id] = nil
        dnsFlows.remove(id)
    }

    private func flush() {
        guard !outbox.isEmpty else { return }
        let batch = outbox
        outbox.removeAll(keepingCapacity: true)
        IPCServer.shared.send(events: batch)
    }

    /// Code-signature identity of the app behind a flow, cached per process (the audit token is unique per process).
    private func identity(for token: Data?) -> AppIdentity {
        guard let token else { return AppIdentity(signingID: nil, teamID: nil, isApple: false, path: "unknown") }
        if let known = identities[token] { return known }

        var code: SecCode?
        var id = AppIdentity(signingID: nil, teamID: nil, isApple: false, path: "unknown")
        if SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token] as CFDictionary, [], &code) == errSecSuccess,
           let code {
            var staticCode: SecStaticCode?
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
                var url: CFURL?
                if SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url { id.path = (url as URL).path }
                var info: CFDictionary?
                if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                   let info = info as? [String: Any] {
                    id.signingID = info[kSecCodeInfoIdentifier as String] as? String
                    // Trust the team only when an Apple-issued certificate backs the signature.
                    if let req = Self.developerRequirement, SecCodeCheckValidity(code, [], req) == errSecSuccess {
                        id.teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
                    }
                }
            }
            if let req = Self.appleRequirement { id.isApple = SecCodeCheckValidity(code, [], req) == errSecSuccess }
        }
        if identities.count > 4096 { identities.removeAll() }
        identities[token] = id
        return id
    }
}
