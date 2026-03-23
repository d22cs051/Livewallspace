import Foundation
import Combine

enum LivewallspaceSharedContract {
    static let appGroupID = "group.com.livewallspace.shared"

    enum Keys {
        static let enabled = "NativeLockScreenIntegrationEnabled"
        static let sourceURL = "LockScreenSourceVideoURL"
        static let processedURL = "LockScreenProcessedVideoURL"
    }

    static var hasAppGroupAccess: Bool {
        guard UserDefaults(suiteName: appGroupID) != nil else {
            return false
        }

        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) != nil
    }

    static func sharedDefaultsOptional() -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func sharedDefaults() -> UserDefaults {
        sharedDefaultsOptional() ?? .standard
    }
}
