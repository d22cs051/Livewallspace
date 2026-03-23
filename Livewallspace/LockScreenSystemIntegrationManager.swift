import AppKit
import Foundation

@MainActor
final class LockScreenSystemIntegrationManager {
    static let shared = LockScreenSystemIntegrationManager()

    static let extensionBundleIdentifier = "com.livewallspace.LivewallspaceLockScreenExtension"
    static let wallpaperAerialsExecutablePath = "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/MacOS/WallpaperAerialsExtension"

    private let preparationService = VideoPreparationService()

    private init() {}

    var isSupportedOS: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    var isConfiguredForNativeIntegration: Bool {
        LivewallspaceSharedContract.hasAppGroupAccess
    }

    var isExtensionInstalled: Bool {
        let manager = FileManager.default

        guard let pluginsFolder = Bundle.main.builtInPlugInsURL,
              let pluginURLs = try? manager.contentsOfDirectory(
                at: pluginsFolder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else {
            return false
        }

        return pluginURLs.contains { pluginURL in
            guard pluginURL.pathExtension == "appex",
                  let bundle = Bundle(url: pluginURL),
                  let identifier = bundle.bundleIdentifier
            else {
                return false
            }

            return identifier == Self.extensionBundleIdentifier
        }
    }

    private var defaults: UserDefaults {
        LivewallspaceSharedContract.sharedDefaults()
    }

    var isEnabled: Bool {
        defaults.bool(forKey: LivewallspaceSharedContract.Keys.enabled)
    }

    func setEnabled(_ enabled: Bool, sourceVideoURL: URL?) async throws -> String {
        guard isSupportedOS else {
            defaults.set(false, forKey: LivewallspaceSharedContract.Keys.enabled)
            return "Native lock screen video requires macOS 15 or later."
        }

        guard isConfiguredForNativeIntegration else {
            defaults.set(false, forKey: LivewallspaceSharedContract.Keys.enabled)
            return "Native integration needs App Group setup first. Open the integration guide and apply the group entitlement in both app and extension targets."
        }

        guard isExtensionInstalled else {
            defaults.set(false, forKey: LivewallspaceSharedContract.Keys.enabled)
            return "Livewallspace lock-screen extension is not installed in this app build. Run from Xcode with the extension target embedded, then reopen Wallpaper settings."
        }

        defaults.set(enabled, forKey: LivewallspaceSharedContract.Keys.enabled)

        guard enabled else {
            return "Native lock screen integration disabled."
        }

        guard let sourceVideoURL else {
            return "Integration enabled. Set a wallpaper video to prepare lock screen media and sync it to Wallpaper."
        }

        _ = try await prepareVideoForSystemIntegration(sourceVideoURL)
        _ = try await SystemWallpaperManifestIntegrationManager.shared.registerCurrentVideo(sourceVideoURL)
        return "Integration enabled. Current video synced to lock screen and added to Custom Videos."
    }

    func syncCurrentVideoIfNeeded(_ sourceVideoURL: URL?) async {
        guard isEnabled,
              isSupportedOS,
              isConfiguredForNativeIntegration,
              isExtensionInstalled,
              let sourceVideoURL
        else {
            return
        }
        _ = try? await prepareVideoForSystemIntegration(sourceVideoURL)
        await SystemWallpaperManifestIntegrationManager.shared.syncCurrentVideoIfNeeded(sourceVideoURL)
    }

    func openWallpaperSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func restartWallpaperAerialsExtensionForLockTransition() {
        do {
            try restartProcess(matchingExecutablePath: Self.wallpaperAerialsExecutablePath)
        } catch {
            // Best-effort pre-lock restart; lock flow should continue even if restart fails.
        }
    }

    func prepareNowForLockTransition(sourceVideoURL: URL?) async {
        guard isEnabled,
              isSupportedOS,
              isConfiguredForNativeIntegration,
              isExtensionInstalled,
              let sourceVideoURL
        else {
            return
        }

        _ = try? await prepareVideoForSystemIntegration(sourceVideoURL)
        await SystemWallpaperManifestIntegrationManager.shared.syncCurrentVideoIfNeeded(sourceVideoURL)
    }

    private func prepareVideoForSystemIntegration(_ sourceVideoURL: URL) async throws -> URL {
        defaults.set(sourceVideoURL.absoluteString, forKey: LivewallspaceSharedContract.Keys.sourceURL)

        let destination = try processedVideoURL()
        try await preparationService.prepareLockScreenVideo(sourceURL: sourceVideoURL, destinationURL: destination)
        defaults.set(destination.absoluteString, forKey: LivewallspaceSharedContract.Keys.processedURL)

        return destination
    }

    private func processedVideoURL() throws -> URL {
        let manager = FileManager.default

        let baseFolder: URL
        if let groupContainer = manager.containerURL(forSecurityApplicationGroupIdentifier: LivewallspaceSharedContract.appGroupID) {
            baseFolder = groupContainer
        } else {
            baseFolder = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        }

        let folder = baseFolder
            .appendingPathComponent("Livewallspace", isDirectory: true)
            .appendingPathComponent("LockScreen", isDirectory: true)

        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("lockscreen-live-source.mov", isDirectory: false)
    }

    private func restartProcess(matchingExecutablePath executablePath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", executablePath]

        try process.run()
        process.waitUntilExit()

        // pkill returns 1 when no process matched; treat that as non-fatal.
        if process.terminationStatus > 1 {
            throw NSError(domain: "Livewallspace", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Failed to restart WallpaperAerialsExtension (status \(process.terminationStatus))."
            ])
        }
    }
}
