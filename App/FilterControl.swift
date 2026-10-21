import AppKit
import Foundation
import NetworkExtension
import Observation
import SystemExtensions

/// Installs the system extension and switches the content filter on and off.
@Observable
final class FilterControl: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = FilterControl()

    enum State: Equatable {
        case checking, off, installing, needsUserApproval, on
        case failed(String)
    }

    private(set) var state: State = .checking
    var onEnabled: (() -> Void)?
    var onDisabled: (() -> Void)?

    override init() {
        super.init()
        if Demo.isOn {
            state = Demo.offline ? .off : .on
            return
        }
        NEFilterManager.shared().loadFromPreferences { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.state = .failed(error.localizedDescription); return }
                self.state = Self.isOurs(NEFilterManager.shared()) ? .on : .off
                if self.state == .on { self.refreshExtension() }
                if self.state == .on { self.onEnabled?() }
            }
        }
    }

    /// Submits an activation for the extension inside this app. macOS replaces an older installed copy
    /// (see `actionForReplacingExtension`) and finishes at once when it is already current.
    private func refreshExtension() {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: IPC.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Whether this build can load the filter at all: it needs a developer team (see project.yml).
    /// Ad-hoc builds (scripts/install.sh without KEKKAI_TEAM) can't, so the app leads with Watch mode instead.
    static var canLoadFilter: Bool { Demo.isOn ? !Demo.offline : !IPC.teamID.isEmpty }

    static func openExtensionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    func turnOn() {
        if Demo.isOn { state = .on; onEnabled?(); return }
        state = .installing
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: IPC.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func turnOff() {
        if Demo.isOn { state = .off; return }
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { _ in
            manager.isEnabled = false
            manager.saveToPreferences { error in
                DispatchQueue.main.async {
                    self.state = error.map { .failed($0.localizedDescription) } ?? .off
                    if error == nil { self.onDisabled?() }
                }
            }
        }
    }

    /// Removes Kekkai's filter configuration and asks macOS to remove the extension. The app then moves itself to the Trash.
    func uninstall(done: @escaping (Error?) -> Void) {
        if Demo.isOn { done(nil); return }
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { _ in
            let finish = {
                let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: IPC.extensionBundleID, queue: .main)
                request.delegate = self
                self.onUninstalled = done
                OSSystemExtensionManager.shared.submitRequest(request)
            }
            if Self.isOurs(manager) || manager.providerConfiguration?.filterDataProviderBundleIdentifier == IPC.extensionBundleID {
                manager.removeFromPreferences { _ in DispatchQueue.main.async(execute: finish) }
            } else {
                DispatchQueue.main.async(execute: finish)
            }
        }
    }

    private var onUninstalled: ((Error?) -> Void)?

    private func enableFilter() {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { error in
            if let error { return self.fail(error) }
            // Never overwrite a filter configuration that is not ours.
            if let existing = manager.providerConfiguration,
               existing.filterDataProviderBundleIdentifier != IPC.extensionBundleID {
                return DispatchQueue.main.async { self.state = .failed("Another content filter configuration is present. Kekkai left it alone.") }
            }
            let config = NEFilterProviderConfiguration()
            config.filterSockets = true
            config.filterPackets = false
            config.filterDataProviderBundleIdentifier = IPC.extensionBundleID
            manager.providerConfiguration = config
            manager.localizedDescription = "Kekkai"
            manager.isEnabled = true
            manager.saveToPreferences { error in
                if let error { return self.fail(error) }
                DispatchQueue.main.async {
                    self.state = .on
                    self.onEnabled?()
                }
            }
        }
    }

    /// Enabled and pointing at our extension. Other filters on the Mac (antivirus, MDM) do not count.
    private static func isOurs(_ manager: NEFilterManager) -> Bool {
        manager.isEnabled && manager.providerConfiguration?.filterDataProviderBundleIdentifier == IPC.extensionBundleID
    }

    private func fail(_ error: Error) {
        DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
    }

    // MARK: OSSystemExtensionRequestDelegate (called on main, see `queue:` above)

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        state = .needsUserApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if let done = onUninstalled { onUninstalled = nil; state = .off; done(nil); return }
        enableFilter()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        if let done = onUninstalled { onUninstalled = nil; done(error); return }
        state = .failed(error.localizedDescription)
    }
}
