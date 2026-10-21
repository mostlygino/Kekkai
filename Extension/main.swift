import Foundation
import NetworkExtension

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
IPCServer.shared.start()
dispatchMain()
