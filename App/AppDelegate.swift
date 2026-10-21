import AppKit
import SwiftUI

/// AppKit hooks SwiftUI scenes don't offer: window placement repair, Dock reopen, and the approval panel's
/// behaviour over full-screen apps.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the main window once it exists, so the Dock icon and the menu bar can bring it back.
    static var openMain: (() -> Void)?

    /// Runs before SwiftUI restores windows: a saved frame that lands on no screen (display unplugged, layout changed)
    /// is dropped, so the window opens centred instead of out of sight.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if Demo.isOn {
            // Demo windows open at the default size, not at whatever the real app saved on this Mac.
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix("NSWindow Frame main") || key.hasPrefix("NSSplitView Subview Frames main") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let screens = NSScreen.screens.map(\.visibleFrame)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame ") {
            guard let saved = UserDefaults.standard.string(forKey: key) else { continue }
            if !Self.savedFrameIsVisible(saved, on: screens) { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// "x y w h sx sy sw sh" (AppKit's saved frame format). Visible when at least 120 x 80 pt of it is on a screen.
    static func savedFrameIsVisible(_ saved: String, on screens: [CGRect]) -> Bool {
        let n = saved.split(separator: " ").compactMap { Double($0) }
        guard n.count >= 4 else { return false }
        let frame = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        return screens.contains { s in
            let i = s.intersection(frame)
            return !i.isNull && i.width >= 120 && i.height >= 80
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `-quitAfter 12`: quit by itself after that many seconds (screenshots and other scripted runs).
        let quitAfter = UserDefaults.standard.double(forKey: "quitAfter")
        if quitAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { NSApp.terminate(nil) }
        }
        warnIfNotInApplications()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            // Fallback: the main window must be there after launch, unless macOS opened us as a login item.
            if !Self.launchedAsLoginItem, !NSApp.windows.contains(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
                Self.openMain?()
            }
            for w in NSApp.windows {
                Self.keepOnScreen(w)
                if Demo.isOn {
                    NSLog("Kekkai window id=%@ title=%@ visible=%d frame=%@", w.identifier?.rawValue ?? "-", w.title,
                          w.isVisible, NSStringFromRect(w.frame))
                }
            }
        }
        // No window observers after launch. Repairing on every move fought window managers that park windows
        // off-screen on purpose (AeroSpace hides workspaces that way): a constant move/repair loop. And
        // didUpdate fires for every window on almost every pass of the event loop.
    }

    /// The approval panel shows over full-screen apps and on every Space, so a waiting connection is never out of
    /// sight. Called once when the panel appears.
    static func configureApprovalPanel() {
        guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("approvals") == true }) else { return }
        w.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    private static var launchedAsLoginItem: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Closing the window leaves Kekkai running in the menu bar; the Dock icon brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.openMain?() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A window restored from another display layout can end up entirely off-screen. Pull it back.
    static func keepOnScreen(_ w: NSWindow) {
        // Status items and the menu bar panel live outside the visible frame on purpose.
        guard w.isVisible, w.styleMask.contains(.titled),
              !savedFrameIsVisible("\(w.frame.minX) \(w.frame.minY) \(w.frame.width) \(w.frame.height)", on: NSScreen.screens.map(\.visibleFrame)),
              let screen = NSScreen.main else { return }
        var f = w.frame
        f.size.width = min(f.width, screen.visibleFrame.width)
        f.size.height = min(f.height, screen.visibleFrame.height)
        f.origin = CGPoint(x: screen.visibleFrame.midX - f.width / 2, y: screen.visibleFrame.midY - f.height / 2)
        w.setFrame(f, display: true)
    }

    /// The system only loads the filter extension from an app in /Applications.
    private func warnIfNotInApplications() {
        guard !Demo.isOn, !Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: "skipLocationWarning") else { return }
        let alert = NSAlert()
        alert.messageText = "Move Kekkai to Applications?"
        alert.informativeText = "macOS only loads Kekkai's network extension when the app is in the Applications folder."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "skipLocationWarning") }
        guard answer == .alertFirstButtonReturn else { return }
        let target = URL(fileURLWithPath: "/Applications").appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.trashItem(at: target, resultingItemURL: nil) }
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: target)
            NSWorkspace.shared.openApplication(at: target, configuration: .init())
            NSApp.terminate(nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

enum Uninstaller {
    /// Confirms, removes the filter and its extension, then moves the app to the Trash and quits.
    static func run(filter: FilterControl) {
        let alert = NSAlert()
        alert.messageText = "Uninstall Kekkai?"
        alert.informativeText = "Kekkai turns off its filter, removes its network extension and moves itself to the Trash. Your rules and history stay in ~/Library/Application Support/Kekkai until you delete them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        filter.uninstall { error in
            if let error {
                let fail = NSAlert(error: error)
                fail.informativeText = "macOS didn't remove the extension: \(error.localizedDescription) You can remove it in System Settings, General, Login Items & Extensions."
                fail.runModal()
                return
            }
            guard !Demo.isOn else { return }
            NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in NSApp.terminate(nil) }
        }
    }
}
