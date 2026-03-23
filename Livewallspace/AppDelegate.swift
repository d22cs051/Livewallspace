import AppKit
import IOKit.ps
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var lockObserversConfigured = false
    private var lastLockExtensionRestartAt: Date?
    private var statusItem: NSStatusItem?
    private var nativeLockScreenItem: NSMenuItem?
    private var continuityLockScreenItem: NSMenuItem?
    private var frameRateItems: [Int: NSMenuItem] = [:]
    private var aspectRatioItems: [WallpaperAspectRatioMode: NSMenuItem] = [:]
    private var launchAtLoginItem: NSMenuItem?
    private var playbackToggleItem: NSMenuItem?
    private var pauseWhenObscuredItem: NSMenuItem?
    private var pauseOnLowBatteryItem: NSMenuItem?
    private var lowBatteryMonitorTimer: Timer?
    private var autoPausedForLowBattery = false
    private let pauseOnLowBatteryDefaultsKey = "PauseOnLowBattery"
    private let lowBatteryThresholdPercent = 20

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force regular app presentation when launched via swift run.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        configureLockScreenObserversIfNeeded()
        configureLowBatteryMonitoringIfNeeded()
        configureStatusItemIfNeeded()
    }

    private func configureStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "Livewallspace")
            button.imagePosition = .imageOnly
            button.toolTip = "Livewallspace"
        }

        let menu = NSMenu()
        menu.delegate = self
        
        menu.addItem(NSMenuItem(title: "Select Video...", action: #selector(selectVideo), keyEquivalent: "o"))

        menu.addItem(.separator())
        let playbackItem = NSMenuItem(title: "Pause", action: #selector(togglePlayback), keyEquivalent: "p")
        playbackToggleItem = playbackItem
        menu.addItem(playbackItem)

        menu.addItem(.separator())
        menu.addItem(makeLockScreenMenuItem())

        menu.addItem(.separator())
        menu.addItem(makeFrameRateMenuItem())
        menu.addItem(makeAspectRatioMenuItem())

        menu.addItem(.separator())
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem = launchItem
        menu.addItem(launchItem)

        let obscuredItem = NSMenuItem(title: "Pause When 70% Obscured", action: #selector(togglePauseWhenObscured), keyEquivalent: "")
        pauseWhenObscuredItem = obscuredItem
        menu.addItem(obscuredItem)

        let lowBatteryItem = NSMenuItem(title: "Pause on Low Battery", action: #selector(togglePauseOnLowBattery), keyEquivalent: "")
        pauseOnLowBatteryItem = lowBatteryItem
        menu.addItem(lowBatteryItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Help", action: #selector(openHelp), keyEquivalent: ""))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        menu.addItem(makeCenteredNoteMenuItem("\tMade with ❤️, In development; bugs are expected."))

        item.menu = menu
        statusItem = item
        refreshMenuState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
    }

    @objc private func selectVideo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .mpeg4Movie,
            .movie,
            .quickTimeMovie,
            .audiovisualContent
        ]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        WallpaperManager.shared.setWallpaperVideo(url: url)
        WallpaperManager.shared.setUserPaused(false)
        
        // Show the main app window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        // Post notification to trigger import in UI (if available)
        NotificationCenter.default.post(
            name: NSNotification.Name("LivewallspaceVideoSelected"),
            object: url
        )
        
        refreshMenuState()
    }

    @objc private func togglePlayback() {
        guard WallpaperManager.shared.selectedVideoURL != nil else {
            refreshMenuState()
            return
        }

        let nextPaused = !WallpaperManager.shared.userPaused
        WallpaperManager.shared.setUserPaused(nextPaused)
        if !nextPaused {
            autoPausedForLowBattery = false
        }
        refreshMenuState()
    }

    @objc private func toggleNativeLockScreen() {
        Task { @MainActor [self] in
            let manager = LockScreenSystemIntegrationManager.shared
            _ = try? await manager.setEnabled(!manager.isEnabled, sourceVideoURL: WallpaperManager.shared.selectedVideoURL)
            refreshMenuState()
        }
    }

    @objc private func toggleLockScreenContinuity() {
        Task { @MainActor [self] in
            let manager = LockScreenContinuityManager.shared
            _ = try? await manager.setEnabled(!manager.isEnabled, sourceVideoURL: WallpaperManager.shared.selectedVideoURL)
            refreshMenuState()
        }
    }

    @objc private func openWallpaperSettings() {
        LockScreenSystemIntegrationManager.shared.openWallpaperSettings()
    }

    @objc private func setFrameRate24() {
        WallpaperManager.shared.setPreferredFrameRate(24)
        refreshMenuState()
    }

    @objc private func setFrameRateOriginal() {
        WallpaperManager.shared.setPreferredFrameRate(0)
        refreshMenuState()
    }

    @objc private func setFrameRate30() {
        WallpaperManager.shared.setPreferredFrameRate(30)
        refreshMenuState()
    }

    @objc private func setFrameRate60() {
        WallpaperManager.shared.setPreferredFrameRate(60)
        refreshMenuState()
    }

    @objc private func setAspectRatioFill() {
        WallpaperManager.shared.setAspectRatioMode(.fill)
        refreshMenuState()
    }

    @objc private func setAspectRatioFit() {
        WallpaperManager.shared.setAspectRatioMode(.fit)
        refreshMenuState()
    }

    @objc private func setAspectRatioStretch() {
        WallpaperManager.shared.setAspectRatioMode(.stretch)
        refreshMenuState()
    }

    @objc private func toggleLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        do {
            if enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Unable to update launch setting"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        refreshMenuState()
    }

    @objc private func togglePauseWhenObscured() {
        let nextValue = !WallpaperManager.shared.pauseWhenObscured
        WallpaperManager.shared.setPauseWhenObscured(nextValue)
        refreshMenuState()
    }

    @objc private func togglePauseOnLowBattery() {
        let nextValue = !UserDefaults.standard.bool(forKey: pauseOnLowBatteryDefaultsKey)
        UserDefaults.standard.set(nextValue, forKey: pauseOnLowBatteryDefaultsKey)
        applyLowBatteryPlaybackPolicy()
        refreshMenuState()
    }

    @objc private func openHelp() {
        let helpPath = FileManager.default.currentDirectoryPath + "/Docs/LockScreen-Extension-Setup.md"
        NSWorkspace.shared.open(URL(fileURLWithPath: helpPath))
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func makeLockScreenMenuItem() -> NSMenuItem {
        let lockScreenSubmenu = NSMenu(title: "Lock Screen")

        let nativeItem = NSMenuItem(
            title: "Native Integration (macOS 15+)",
            action: #selector(toggleNativeLockScreen),
            keyEquivalent: ""
        )
        nativeLockScreenItem = nativeItem
        lockScreenSubmenu.addItem(nativeItem)

        let continuityItem = NSMenuItem(
            title: "Continuity Snapshot",
            action: #selector(toggleLockScreenContinuity),
            keyEquivalent: ""
        )
        continuityLockScreenItem = continuityItem
        lockScreenSubmenu.addItem(continuityItem)

        lockScreenSubmenu.addItem(.separator())
        lockScreenSubmenu.addItem(NSMenuItem(title: "Open Wallpaper Settings", action: #selector(openWallpaperSettings), keyEquivalent: ""))

        let root = NSMenuItem(title: "Lock Screen", action: nil, keyEquivalent: "")
        root.submenu = lockScreenSubmenu
        return root
    }

    private func makeFrameRateMenuItem() -> NSMenuItem {
        let frameRateSubmenu = NSMenu(title: "Frame Rate")

        let frameOriginal = NSMenuItem(title: "Original", action: #selector(setFrameRateOriginal), keyEquivalent: "")
        let frame24 = NSMenuItem(title: "24 fps", action: #selector(setFrameRate24), keyEquivalent: "")
        let frame30 = NSMenuItem(title: "30 fps", action: #selector(setFrameRate30), keyEquivalent: "")
        let frame60 = NSMenuItem(title: "60 fps", action: #selector(setFrameRate60), keyEquivalent: "")

        frameRateItems[0] = frameOriginal
        frameRateItems[24] = frame24
        frameRateItems[30] = frame30
        frameRateItems[60] = frame60

        frameRateSubmenu.addItem(frameOriginal)
        frameRateSubmenu.addItem(frame24)
        frameRateSubmenu.addItem(frame30)
        frameRateSubmenu.addItem(frame60)

        let root = NSMenuItem(title: "Frame Rate", action: nil, keyEquivalent: "")
        root.submenu = frameRateSubmenu
        return root
    }

    private func makeAspectRatioMenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Aspect Ratio")

        let fillItem = NSMenuItem(title: "Fill", action: #selector(setAspectRatioFill), keyEquivalent: "")
        let fitItem = NSMenuItem(title: "Fit", action: #selector(setAspectRatioFit), keyEquivalent: "")
        let stretchItem = NSMenuItem(title: "Stretch", action: #selector(setAspectRatioStretch), keyEquivalent: "")

        aspectRatioItems[.fill] = fillItem
        aspectRatioItems[.fit] = fitItem
        aspectRatioItems[.stretch] = stretchItem

        submenu.addItem(fillItem)
        submenu.addItem(fitItem)
        submenu.addItem(stretchItem)

        let root = NSMenuItem(title: "Aspect Ratio", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    private func makeCenteredNoteMenuItem(_ title: String) -> NSMenuItem {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.paragraphStyle: paragraph]
        )
        item.isEnabled = false
        return item
    }

    private func refreshMenuState() {
        let nativeManager = LockScreenSystemIntegrationManager.shared
        nativeLockScreenItem?.state = nativeManager.isEnabled ? .on : .off
        nativeLockScreenItem?.isEnabled = nativeManager.isSupportedOS

        continuityLockScreenItem?.state = LockScreenContinuityManager.shared.isEnabled ? .on : .off

        let currentFPS = WallpaperManager.shared.preferredFrameRate
        frameRateItems.forEach { fps, item in
            item.state = (fps == currentFPS) ? .on : .off
        }

        let currentAspect = WallpaperManager.shared.aspectRatioMode
        aspectRatioItems.forEach { mode, item in
            item.state = (mode == currentAspect) ? .on : .off
        }

        launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        pauseWhenObscuredItem?.state = WallpaperManager.shared.pauseWhenObscured ? .on : .off
        pauseOnLowBatteryItem?.state = UserDefaults.standard.bool(forKey: pauseOnLowBatteryDefaultsKey) ? .on : .off

        let hasVideo = WallpaperManager.shared.selectedVideoURL != nil
        playbackToggleItem?.isEnabled = hasVideo
        playbackToggleItem?.title = WallpaperManager.shared.userPaused ? "Play" : "Pause"
    }

    private func configureLowBatteryMonitoringIfNeeded() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLowPowerModeChanged),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )

        lowBatteryMonitorTimer?.invalidate()
        lowBatteryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.applyLowBatteryPlaybackPolicy()
        }
        applyLowBatteryPlaybackPolicy()
    }

    @objc private func handleLowPowerModeChanged() {
        applyLowBatteryPlaybackPolicy()
    }

    private func applyLowBatteryPlaybackPolicy() {
        let isEnabled = UserDefaults.standard.bool(forKey: pauseOnLowBatteryDefaultsKey)
        guard isEnabled else {
            if autoPausedForLowBattery,
               WallpaperManager.shared.selectedVideoURL != nil {
                WallpaperManager.shared.setUserPaused(false)
            }
            autoPausedForLowBattery = false
            return
        }

        let isLowBattery = isSystemInLowBatteryState()
        if isLowBattery,
           !WallpaperManager.shared.userPaused,
           WallpaperManager.shared.selectedVideoURL != nil {
            WallpaperManager.shared.setUserPaused(true)
            autoPausedForLowBattery = true
        } else if !isLowBattery, autoPausedForLowBattery,
                  WallpaperManager.shared.selectedVideoURL != nil {
            WallpaperManager.shared.setUserPaused(false)
            autoPausedForLowBattery = false
        }
    }

    private func isSystemInLowBatteryState() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return true
        }

        guard isRunningOnBattery(), let battery = currentBatteryPercent() else {
            return false
        }
        return battery <= lowBatteryThresholdPercent
    }

    private func isRunningOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return false
        }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let state = info[kIOPSPowerSourceStateKey as String] as? String
            else {
                continue
            }

            if state == kIOPSBatteryPowerValue {
                return true
            }
        }
        return false
    }

    private func currentBatteryPercent() -> Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return nil
        }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey as String] as? Int,
                  let max = info[kIOPSMaxCapacityKey as String] as? Int,
                  max > 0
            else {
                continue
            }

            return Int((Double(current) / Double(max)) * 100.0)
        }
        return nil
    }

    private func configureLockScreenObserversIfNeeded() {
        guard !lockObserversConfigured else { return }
        lockObserversConfigured = true

        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(handleScreenAboutToLock),
            name: Notification.Name("com.apple.screenIsAboutToLock"),
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleScreenLocked),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
    }

    @objc private func handleScreenAboutToLock() {
        Task { @MainActor in
            await LockScreenSystemIntegrationManager.shared.prepareNowForLockTransition(
                sourceVideoURL: WallpaperManager.shared.selectedVideoURL
            )
            restartLockScreenExtensionIfNeeded(force: true)
        }
    }

    @objc private func handleScreenLocked() {
        // Fallback for systems that don't emit about-to-lock notifications.
        restartLockScreenExtensionIfNeeded(force: false)
    }

    private func restartLockScreenExtensionIfNeeded(force: Bool) {
        let now = Date()
        if !force,
           let last = lastLockExtensionRestartAt,
           now.timeIntervalSince(last) < 2.0 {
            return
        }

        lastLockExtensionRestartAt = now
        LockScreenSystemIntegrationManager.shared.restartWallpaperAerialsExtensionForLockTransition()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lowBatteryMonitorTimer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
}
