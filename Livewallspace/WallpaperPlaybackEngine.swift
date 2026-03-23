import AppKit
import AVFoundation
import Combine

@MainActor
final class WallpaperPlaybackEngine: ObservableObject {
    let player: AVQueuePlayer
    @Published private(set) var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    @Published private(set) var preferredFrameRate: Int = 30

    private var looper: AVPlayerLooper?
    private var currentVideoURL: URL?
    private var userPaused = false
    private var screenSleeping = false
    private var obscuredPaused = false
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = false

        subscribeWorkspaceNotifications()
        recomputePlaybackState()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
    }

    func setVideoURL(_ url: URL?) {
        currentVideoURL = url
        looper = nil
        player.removeAllItems()

        guard let url else {
            recomputePlaybackState()
            return
        }

        let item = AVPlayerItem(url: url)
        applyFrameRatePreference(to: item)
        looper = AVPlayerLooper(player: player, templateItem: item)
        recomputePlaybackState()
    }

    func setUserPaused(_ paused: Bool) {
        userPaused = paused
        recomputePlaybackState()
    }

    func setObscuredPaused(_ paused: Bool) {
        obscuredPaused = paused
        recomputePlaybackState()
    }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        videoGravity = gravity
    }

    func setPreferredFrameRate(_ fps: Int) {
        preferredFrameRate = (fps == 0) ? 0 : max(12, min(120, fps))
        if currentVideoURL != nil {
            setVideoURL(currentVideoURL)
        }
    }

    private func applyFrameRatePreference(to item: AVPlayerItem) {
        guard preferredFrameRate > 0 else {
            item.videoComposition = nil
            return
        }

        let targetFrameRate = preferredFrameRate
        if #available(macOS 26.0, *) {
            Task {
                do {
                    var configuration = try await AVVideoComposition.Configuration(for: item.asset)
                    configuration.frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
                    let composition = AVVideoComposition(configuration: configuration)
                    await MainActor.run {
                        item.videoComposition = composition
                    }
                } catch {
                    await MainActor.run {
                        item.videoComposition = nil
                    }
                }
            }
        } else {
            item.videoComposition = nil
        }
    }

    private func subscribeWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recomputePlaybackState()
                }
            }
        )

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.screenSleeping = true
                    self?.recomputePlaybackState()
                }
            }
        )

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.screenSleeping = false
                    self?.recomputePlaybackState()
                }
            }
        )

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.screenSleeping = false
                    self?.recomputePlaybackState()
                }
            }
        )
    }

    private func recomputePlaybackState() {
        let shouldPause = userPaused || screenSleeping || obscuredPaused
        if shouldPause || player.items().isEmpty {
            player.pause()
            return
        }
        player.play()
    }
}
