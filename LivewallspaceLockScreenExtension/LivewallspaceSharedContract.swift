import Foundation

enum LivewallspaceSharedContract {
    static let appGroupID = "group.com.livewallspace.shared"

    enum Keys {
        static let enabled = "NativeLockScreenIntegrationEnabled"
        static let sourceURL = "LockScreenSourceVideoURL"
        static let processedURL = "LockScreenProcessedVideoURL"
    }
}
