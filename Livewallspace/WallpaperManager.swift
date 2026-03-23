import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI
import Combine

enum WallpaperAspectRatioMode: String {
    case fill
    case fit
    case stretch

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill:
            return .resizeAspectFill
        case .fit:
            return .resizeAspect
        case .stretch:
            return .resize
        }
    }
}

@MainActor
final class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()

    @Published private(set) var windowsByScreen: [NSScreen: NSWindow] = [:]
    @Published private(set) var selectedVideoURL: URL?
    @Published private(set) var userPaused: Bool = false
    @Published private(set) var preferredFrameRate: Int = 30
    @Published private(set) var aspectRatioMode: WallpaperAspectRatioMode = .fill
    @Published private(set) var pauseWhenObscured: Bool = false

    private var enginesByScreen: [NSScreen: WallpaperPlaybackEngine] = [:]

    var activeWallpaperCount: Int {
        windowsByScreen.count
    }

    private var isStarted = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var obscuredMonitorTimer: Timer?
    private let selectedVideoDefaultsKey = "SelectedWallpaperVideoURL"
    private let preferredFrameRateDefaultsKey = "PreferredWallpaperFrameRate"
    private let aspectRatioDefaultsKey = "WallpaperAspectRatioMode"
    private let pauseWhenObscuredDefaultsKey = "PauseWhenWallpaperObscured"
    private let obscuredPauseThreshold: Double = 0.70

    private init() {}

    deinit {
        obscuredMonitorTimer?.invalidate()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        subscribeToScreenConfigurationChanges()
        restorePersistedSelectionIfNeeded()
        restorePlaybackPreferencesIfNeeded()
        updateObscuredMonitoring()
        syncWindowsWithCurrentScreens()
        subscribeFrontAppChangesIfNeeded()
        recomputeObscuredPauseState()
    }

    func resyncScreens() {
        syncWindowsWithCurrentScreens()
    }

    func hideAllWallpaperWindows() {
        windowsByScreen.values.forEach { $0.orderOut(nil) }
    }

    func showAllWallpaperWindows() {
        windowsByScreen.values.forEach { $0.orderBack(nil) }
    }

    func setWallpaperVideo(url: URL?) {
        selectedVideoURL = url
        UserDefaults.standard.set(url?.absoluteString, forKey: selectedVideoDefaultsKey)

        for engine in enginesByScreen.values {
            engine.setVideoURL(url)
        }

        Task { @MainActor in
            await LockScreenSystemIntegrationManager.shared.syncCurrentVideoIfNeeded(url)
        }

        Task { @MainActor in
            await LockScreenContinuityManager.shared.syncFromCurrentVideoIfNeeded(url)
        }

        Task { @MainActor in
            await SystemWallpaperManifestIntegrationManager.shared.syncCurrentVideoIfNeeded(url)
        }
    }

    private func restorePersistedSelectionIfNeeded() {
        guard selectedVideoURL == nil,
              let storedURLString = UserDefaults.standard.string(forKey: selectedVideoDefaultsKey),
              let storedURL = URL(string: storedURLString)
        else {
            return
        }

        if storedURL.isFileURL, !FileManager.default.fileExists(atPath: storedURL.path) {
            UserDefaults.standard.removeObject(forKey: selectedVideoDefaultsKey)
            return
        }

        setWallpaperVideo(url: storedURL)
    }

    func setUserPaused(_ paused: Bool) {
        userPaused = paused
        for engine in enginesByScreen.values {
            engine.setUserPaused(paused)
        }
    }

    func setPreferredFrameRate(_ fps: Int) {
        let normalized = (fps == 0) ? 0 : max(12, min(120, fps))
        preferredFrameRate = normalized
        UserDefaults.standard.set(normalized, forKey: preferredFrameRateDefaultsKey)

        for engine in enginesByScreen.values {
            engine.setPreferredFrameRate(normalized)
        }
    }

    func setAspectRatioMode(_ mode: WallpaperAspectRatioMode) {
        aspectRatioMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: aspectRatioDefaultsKey)

        for engine in enginesByScreen.values {
            engine.setVideoGravity(mode.videoGravity)
        }
    }

    func setPauseWhenObscured(_ enabled: Bool) {
        pauseWhenObscured = enabled
        UserDefaults.standard.set(enabled, forKey: pauseWhenObscuredDefaultsKey)
        updateObscuredMonitoring()
        recomputeObscuredPauseState()
    }

    private func subscribeToScreenConfigurationChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncWindowsWithCurrentScreens()
            }
        }
        notificationTokens.append(token)
    }

    private func subscribeFrontAppChangesIfNeeded() {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recomputeObscuredPauseState()
            }
        }
        notificationTokens.append(token)
    }

    private func restorePlaybackPreferencesIfNeeded() {
        let defaults = UserDefaults.standard

        if let storedFPS = defaults.object(forKey: preferredFrameRateDefaultsKey) as? Int {
            preferredFrameRate = (storedFPS == 0) ? 0 : max(12, min(120, storedFPS))
        }

        if let rawMode = defaults.string(forKey: aspectRatioDefaultsKey),
           let mode = WallpaperAspectRatioMode(rawValue: rawMode)
        {
            aspectRatioMode = mode
        }

        pauseWhenObscured = defaults.bool(forKey: pauseWhenObscuredDefaultsKey)
    }

    private func recomputeObscuredPauseState() {
        guard pauseWhenObscured else {
            for engine in enginesByScreen.values {
                engine.setObscuredPaused(false)
            }
            return
        }

        let screens = NSScreen.screens
        let totalScreenArea = screens.reduce(0.0) { partial, screen in
            partial + Double(screen.frame.width * screen.frame.height)
        }

        guard totalScreenArea > 0 else {
            for engine in enginesByScreen.values {
                engine.setObscuredPaused(false)
            }
            return
        }

        let visibleWindowRects = visibleForegroundWindowRects()
        let obscuredWeightedArea = screens.reduce(0.0) { partial, screen in
            let screenArea = Double(screen.frame.width * screen.frame.height)
            let obscuredRatio = obscuredRatio(on: screen.frame, by: visibleWindowRects)
            return partial + (screenArea * obscuredRatio)
        }

        let shouldPauseForObscured = (obscuredWeightedArea / totalScreenArea) >= obscuredPauseThreshold

        for engine in enginesByScreen.values {
            engine.setObscuredPaused(shouldPauseForObscured)
        }
    }

    private func updateObscuredMonitoring() {
        obscuredMonitorTimer?.invalidate()
        obscuredMonitorTimer = nil

        guard pauseWhenObscured else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recomputeObscuredPauseState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        obscuredMonitorTimer = timer
    }

    private func visibleForegroundWindowRects() -> [CGRect] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowInfo.compactMap { info in
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { return nil }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.05 else { return nil }

            if let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
               ownerPID == ProcessInfo.processInfo.processIdentifier {
                return nil
            }

            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                return nil
            }

            guard bounds.width > 8,
                  bounds.height > 8
            else {
                return nil
            }

            return bounds
        }
    }

    private func obscuredRatio(on screenFrame: CGRect, by windowRects: [CGRect]) -> Double {
        guard !windowRects.isEmpty, screenFrame.width > 0, screenFrame.height > 0 else {
            return 0
        }

        let columns = 24
        let rows = 14
        let totalSamples = columns * rows
        var coveredSamples = 0

        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(
                    x: screenFrame.minX + ((CGFloat(column) + 0.5) * screenFrame.width / CGFloat(columns)),
                    y: screenFrame.minY + ((CGFloat(row) + 0.5) * screenFrame.height / CGFloat(rows))
                )

                if windowRects.contains(where: { $0.contains(point) }) {
                    coveredSamples += 1
                }
            }
        }

        return Double(coveredSamples) / Double(totalSamples)
    }

    private func syncWindowsWithCurrentScreens() {
        let activeScreens = NSScreen.screens
        let activeKeys = Set(activeScreens)
        let existingKeys = Set(windowsByScreen.keys)

        let removed = existingKeys.subtracting(activeKeys)
        for screen in removed {
            destroyWallpaperWindow(for: screen)
        }

        let added = activeKeys.subtracting(existingKeys)
        for screen in added {
            createWallpaperWindow(for: screen)
        }

        // Keep geometry in sync in case display arrangement changed.
        for screen in activeScreens {
            windowsByScreen[screen]?.setFrame(screen.frame, display: true)
        }
    }

    private func createWallpaperWindow(for screen: NSScreen) {
        guard windowsByScreen[screen] == nil else { return }

        let engine = WallpaperPlaybackEngine()
        engine.setUserPaused(userPaused)
        engine.setObscuredPaused(false)
        engine.setPreferredFrameRate(preferredFrameRate)
        engine.setVideoGravity(aspectRatioMode.videoGravity)
        engine.setVideoURL(selectedVideoURL)

        let window = DesktopWallpaperWindow(screen: screen)
        let contentView = NSHostingView(rootView: VideoPlayerView(engine: engine))
        window.contentView = contentView
        window.orderBack(nil)

        enginesByScreen[screen] = engine
        windowsByScreen[screen] = window
        recomputeObscuredPauseState()
    }

    private func destroyWallpaperWindow(for screen: NSScreen) {
        guard let window = windowsByScreen.removeValue(forKey: screen) else { return }
        enginesByScreen[screen] = nil
        window.orderOut(nil)
        window.close()
    }
}
