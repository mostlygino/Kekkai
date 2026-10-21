import AppKit
import UserNotifications

/// Notification Centre alerts for approvals, with Allow and Block right on the notification.
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()
    private weak var store: Store?
    private var seen: Set<String> = []

    func attach(_ store: Store) {
        self.store = store
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: "allow", title: "Allow")
        let block = UNNotificationAction(identifier: "block", title: "Block", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: "approval", actions: [allow, block], intentIdentifiers: [])])
        store.onApprovalsChanged = { [weak self] in self?.approvalsChanged($0) }
    }

    private func approvalsChanged(_ requests: [ApprovalRequest]) {
        let ids = Set(requests.map(\.id))
        let fresh = requests.filter { !seen.contains($0.id) }
        // Answered or expired requests: take their notifications away.
        let gone = seen.subtracting(ids)
        if !gone.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Array(gone)) }
        seen = ids
        if !fresh.isEmpty { PanelOpener.openApprovals?() }
        guard UserDefaults.standard.object(forKey: "notifyApprovals") as? Bool ?? true, !NSApp.isActive, !fresh.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for req in fresh {
                let content = UNMutableNotificationContent()
                content.title = "\(req.app.title) wants to connect"
                content.body = "To \(req.hosts.first ?? req.ips.first ?? "the network")\(req.count > 1 ? " and \(req.count - 1) more" : ""). \(req.app.signatureSummary)."
                content.categoryIdentifier = "approval"
                content.userInfo = ["key": req.id]
                content.interruptionLevel = .timeSensitive
                center.add(UNNotificationRequest(identifier: req.id, content: content, trigger: nil))
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let key = response.notification.request.content.userInfo["key"] as? String
        DispatchQueue.main.async {
            defer { done() }
            guard let store = self.store, let req = store.approvals.first(where: { $0.id == key }) else { return }
            let remember = UserDefaults.standard.object(forKey: "rememberApproval") as? Bool ?? true
            switch response.actionIdentifier {
            case "allow": store.decide(req, allow: true, remember: remember)
            case "block": store.decide(req, allow: false, remember: remember)
            default: NSApp.activate()   // clicked the notification itself: the panel is already up
            }
        }
    }
}
