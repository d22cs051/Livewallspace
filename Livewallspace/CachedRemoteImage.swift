import SwiftUI
import AppKit
import Combine

private enum LivewallspaceImageCache {
    static let memory = NSCache<NSURL, NSImage>()

    static func configureURLCacheIfNeeded() {
        if URLCache.shared.memoryCapacity >= 64 * 1024 * 1024 {
            return
        }

        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            diskPath: "livewallspace-image-cache"
        )
    }
}

@MainActor
private final class CachedRemoteImageLoader: ObservableObject {
    @Published var image: NSImage?

    private var loadTask: Task<Void, Never>?

    func load(url: URL?) {
        loadTask?.cancel()

        guard let url else {
            image = nil
            return
        }

        LivewallspaceImageCache.configureURLCacheIfNeeded()

        if let cached = LivewallspaceImageCache.memory.object(forKey: url as NSURL) {
            image = cached
            return
        }

        loadTask = Task {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 30

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled, let loaded = NSImage(data: data) else { return }

                LivewallspaceImageCache.memory.setObject(loaded, forKey: url as NSURL)
                image = loaded
            } catch {
                guard !Task.isCancelled else { return }
                image = nil
            }
        }
    }
}

struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    let placeholder: Placeholder

    @StateObject private var loader = CachedRemoteImageLoader()

    init(url: URL?, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder()
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: url) {
            loader.load(url: url)
        }
    }
}
