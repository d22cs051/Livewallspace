import AppKit
import Foundation
import ServiceManagement
import Combine

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var startOnLoginEnabled = false
    @Published var nativeLockScreenIntegrationEnabled = false
    @Published private(set) var nativeLockScreenSupported = false
    @Published private(set) var nativeLockScreenConfigured = false
    @Published private(set) var nativeLockScreenExtensionInstalled = false
    @Published var lockScreenContinuityEnabled = false
    @Published var cacheSizeBytes: Int64 = 0
    @Published var statusMessage: String?
    @Published var systemCatalogSyncInProgress = false

    private let fileManager = FileManager.default
    private let continuityManager = LockScreenContinuityManager.shared
    private let nativeLockScreenManager = LockScreenSystemIntegrationManager.shared
    private var syncStatusObserver: NSObjectProtocol?

    init() {
        syncStatusObserver = NotificationCenter.default.addObserver(
            forName: .livewallspaceSystemCatalogSyncStatus,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let message = notification.userInfo?["message"] as? String else { return }
            Task { @MainActor [weak self] in
                self?.statusMessage = message
            }
        }

        refreshStartOnLoginStatus()
        refreshNativeLockScreenStatus()
        refreshLockScreenContinuityStatus()
        refreshCacheSize()
    }

    deinit {
        if let syncStatusObserver {
            NotificationCenter.default.removeObserver(syncStatusObserver)
        }
    }

    func syncCurrentVideoToSystemCatalog() {
        guard let selectedVideo = WallpaperManager.shared.selectedVideoURL else {
            statusMessage = "Select a wallpaper video first, then run sync."
            return
        }

        systemCatalogSyncInProgress = true

        Task { @MainActor in
            defer { systemCatalogSyncInProgress = false }

            do {
                let result = try await SystemWallpaperManifestIntegrationManager.shared.registerCurrentVideo(selectedVideo)
                statusMessage = result
            } catch {
                statusMessage = "System Wallpaper sync failed: \(error.localizedDescription)"
            }
        }
    }

    func refreshNativeLockScreenStatus() {
        nativeLockScreenSupported = nativeLockScreenManager.isSupportedOS
        nativeLockScreenConfigured = nativeLockScreenManager.isConfiguredForNativeIntegration
        nativeLockScreenExtensionInstalled = nativeLockScreenManager.isExtensionInstalled
        nativeLockScreenIntegrationEnabled = nativeLockScreenManager.isEnabled
    }

    func setNativeLockScreenIntegration(_ enabled: Bool) {
        Task {
            do {
                let message = try await nativeLockScreenManager.setEnabled(
                    enabled,
                    sourceVideoURL: WallpaperManager.shared.selectedVideoURL
                )
                refreshNativeLockScreenStatus()
                statusMessage = message
            } catch {
                refreshNativeLockScreenStatus()
                statusMessage = "Unable to update native lock screen integration: \(error.localizedDescription)"
            }
        }
    }

    func openWallpaperSettingsForIntegration() {
        nativeLockScreenManager.openWallpaperSettings()

        guard let selectedVideo = WallpaperManager.shared.selectedVideoURL else {
            statusMessage = "Opened Wallpaper settings. Select a video first, then click Sync Current Video to System Catalog."
            return
        }

        Task { @MainActor in
            do {
                _ = try await SystemWallpaperManifestIntegrationManager.shared.registerCurrentVideo(selectedVideo)
                statusMessage = "Opened Wallpaper settings. Synced current video. Look under Custom Videos."
            } catch {
                statusMessage = "Opened Wallpaper settings, but sync failed: \(error.localizedDescription)"
            }
        }
    }

    func openIntegrationGuide() {
        let guidePath = FileManager.default.currentDirectoryPath + "/Docs/LockScreen-Extension-Setup.md"
        NSWorkspace.shared.open(URL(fileURLWithPath: guidePath))
    }

    func refreshStartOnLoginStatus() {
        startOnLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setStartOnLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            startOnLoginEnabled = enabled
            statusMessage = nil
        } catch {
            startOnLoginEnabled = SMAppService.mainApp.status == .enabled
            statusMessage = "Unable to update login preference: \(error.localizedDescription)"
        }
    }

    func refreshLockScreenContinuityStatus() {
        lockScreenContinuityEnabled = continuityManager.isEnabled
    }

    func setLockScreenContinuity(_ enabled: Bool) {
        Task {
            do {
                let message = try await continuityManager.setEnabled(
                    enabled,
                    sourceVideoURL: WallpaperManager.shared.selectedVideoURL
                )
                lockScreenContinuityEnabled = continuityManager.isEnabled
                statusMessage = message
            } catch {
                lockScreenContinuityEnabled = continuityManager.isEnabled
                statusMessage = "Unable to update lock screen continuity: \(error.localizedDescription)"
            }
        }
    }

    func refreshCacheSize() {
        let url = cacheDirectoryURL()
        cacheSizeBytes = directorySize(at: url)
    }

    func clearCache() {
        let url = cacheDirectoryURL()

        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            cacheSizeBytes = 0
            statusMessage = nil
        } catch {
            statusMessage = "Unable to clear cache: \(error.localizedDescription)"
            refreshCacheSize()
        }
    }

    func cacheSizeLabel() -> String {
        ByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .file)
    }

    private func cacheDirectoryURL() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Livewallspace", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true,
                let size = values.fileSize
            else {
                continue
            }
            total += Int64(size)
        }
        return total
    }
}
