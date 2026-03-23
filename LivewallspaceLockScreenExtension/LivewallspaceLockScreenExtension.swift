import Foundation
import SwiftUI
import AVFoundation
import AppKit
import Combine
import ExtensionFoundation

@main
struct LivewallspaceLockScreenExtensionMain: AppExtension {
    init() {}

    var configuration: some AppExtensionConfiguration {
        ConnectionHandler { _ in
            true
        }
    }
}

final class LivewallspaceLockScreenExtensionEntry: NSObject {}

@MainActor
final class LivewallspaceLockScreenExtensionViewModel: ObservableObject {
    @Published var player: AVQueuePlayer = AVQueuePlayer()

    private var looper: AVPlayerLooper?
    private let defaults = UserDefaults(suiteName: LivewallspaceSharedContract.appGroupID)
    private var currentVideoURL: URL?
    private var bootstrapRetryTask: Task<Void, Never>?

    func loadPreparedVideo() {
        Task { @MainActor in
            guard let url = await resolvePreparedVideoURL() else {
                scheduleBootstrapRetryIfNeeded()
                return
            }

            bootstrapRetryTask?.cancel()
            bootstrapRetryTask = nil

            guard currentVideoURL != url else { return }
            currentVideoURL = url

            looper = nil
            player.removeAllItems()

            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: player, templateItem: item)
            player.actionAtItemEnd = .none
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = false
            player.play()
        }
    }

    private func scheduleBootstrapRetryIfNeeded() {
        guard bootstrapRetryTask == nil else { return }

        bootstrapRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                self.loadPreparedVideo()
                if self.currentVideoURL != nil {
                    return
                }
            }

            self.bootstrapRetryTask = nil
        }
    }

    private func resolvePreparedVideoURL() async -> URL? {
        let integrationEnabled = defaults?.bool(forKey: LivewallspaceSharedContract.Keys.enabled) == true

        if let raw = defaults?.string(forKey: LivewallspaceSharedContract.Keys.processedURL),
           let url = parseURL(raw),
           FileManager.default.fileExists(atPath: url.path),
           await isPlayable(url: url) {
            return url
        }

        // If a processed URL is missing or stale but integration has been enabled before,
        // continue trying to locate the latest prepared video in the shared container.
        if !integrationEnabled && defaults?.string(forKey: LivewallspaceSharedContract.Keys.processedURL) == nil {
            return nil
        }

        // Fallback: discover latest prepared lock-screen file in app-group container.
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LivewallspaceSharedContract.appGroupID) else {
            return nil
        }

        let candidates = [
            container.appendingPathComponent("Livewallspace/LockScreen", isDirectory: true),
            container.appendingPathComponent("Livewallspace/LockScreenRuntime", isDirectory: true)
        ]

        var allVideos: [URL] = []
        for folder in candidates {
            if let items = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                allVideos.append(contentsOf: items.filter { $0.pathExtension.lowercased() == "mov" })
            }
        }

        let sorted = allVideos.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return l > r
        }

        var latestPlayable: URL?
        for candidate in sorted {
            if await isPlayable(url: candidate) {
                latestPlayable = candidate
                break
            }
        }

        if let latestPlayable {
            defaults?.set(latestPlayable.absoluteString, forKey: LivewallspaceSharedContract.Keys.processedURL)
        }

        return latestPlayable
    }

    private func parseURL(_ raw: String) -> URL? {
        if let url = URL(string: raw), !url.path.isEmpty {
            return url
        }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw)
        }
        return nil
    }

    private func isPlayable(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            return try await asset.load(.isPlayable)
        } catch {
            return false
        }
    }
}

struct LivewallspaceLockScreenExtensionView: View {
    @StateObject private var viewModel = LivewallspaceLockScreenExtensionViewModel()

    var body: some View {
        ZStack {
            LockScreenPlayerRepresentable(player: viewModel.player)
                .ignoresSafeArea()
        }
        .task {
            viewModel.loadPreparedVideo()
        }
        .onReceive(Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()) { _ in
            viewModel.loadPreparedVideo()
        }
    }
}

struct LockScreenPlayerRepresentable: NSViewRepresentable {
    let player: AVQueuePlayer

    func makeNSView(context: Context) -> LockScreenPlayerView {
        let view = LockScreenPlayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: LockScreenPlayerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}

final class LockScreenPlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        playerLayer.frame = bounds
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        playerLayer.frame = bounds
    }

    override func layout() {
        super.layout()
        guard playerLayer.frame != bounds else { return }
        playerLayer.frame = bounds
    }
}
