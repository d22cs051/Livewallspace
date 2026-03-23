import SwiftUI
import SwiftData
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import AppKit

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var wallpaperManager = WallpaperManager.shared

    @Query(sort: [SortDescriptor(\VideoItem.createdAt, order: .reverse)])
    private var savedVideos: [VideoItem]

    @State private var statusMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Library")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Saved wallpapers and quick access")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.76))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Current Selection")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    if let currentURL = wallpaperManager.selectedVideoURL {
                        CurrentSelectedVideoCard(
                            videoURL: currentURL,
                            onApply: {
                                wallpaperManager.setWallpaperVideo(url: currentURL)
                                statusMessage = "Applied: \(currentURL.deletingPathExtension().lastPathComponent)"
                            }
                        )
                    } else {
                        EmptyLibraryCard(title: "No active video selected")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Saved Videos")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 210), spacing: 14)
                        ],
                        spacing: 14
                    ) {
                        if savedVideos.isEmpty {
                            EmptyLibraryCard(title: "No videos saved yet")
                        }

                        ForEach(savedVideos) { item in
                            SavedVideoCard(
                                item: item,
                                onApply: { applySavedVideo(item) },
                                onDelete: { deleteSavedVideo(item) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .task(id: savedVideos.count) {
            await backfillMissingThumbnails()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LivewallspaceVideoSelected"))) { notification in
            guard let url = notification.object as? URL else { return }
            saveVideoIfNeeded(url)
        }
    }

    private func saveVideoIfNeeded(_ url: URL) {
        Task {
            do {
                let descriptor = FetchDescriptor<VideoItem>(
                    predicate: #Predicate { item in
                        item.urlString == url.absoluteString
                    }
                )

                if try modelContext.fetch(descriptor).isEmpty {
                    let thumbnailURL = await generateVideoThumbnail(from: url)
                    await MainActor.run {
                        let item = VideoItem(
                            url: url,
                            name: url.deletingPathExtension().lastPathComponent,
                            category: "User",
                            thumbnailURL: thumbnailURL
                        )
                        modelContext.insert(item)
                        statusMessage = "Imported from menu: \(item.name)"
                    }
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Could not import: \(error.localizedDescription)"
                }
            }
        }
    }

    private func generateVideoThumbnail(from videoURL: URL) async -> URL? {
        guard videoURL.isFileURL, FileManager.default.fileExists(atPath: videoURL.path) else {
            return nil
        }

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let hash = abs(videoURL.path.hashValue)
        guard let thumbnailURL = cacheDir?.appendingPathComponent("thumb-\(hash).png") else {
            return nil
        }

        if FileManager.default.fileExists(atPath: thumbnailURL.path) {
            return thumbnailURL
        }

        do {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true

            let times = [
                CMTime(seconds: 0.0, preferredTimescale: 600),
                CMTime(seconds: 0.35, preferredTimescale: 600),
                CMTime(seconds: 1.0, preferredTimescale: 600)
            ]

            var cgImage: CGImage?
            for time in times {
                do {
                    cgImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                        generator.generateCGImageAsynchronously(for: time) { generatedImage, _, error in
                            if let error {
                                continuation.resume(throwing: error)
                                return
                            }
                            guard let generatedImage else {
                                continuation.resume(throwing: NSError(domain: "Livewallspace", code: 1001, userInfo: nil))
                                return
                            }
                            continuation.resume(returning: generatedImage)
                        }
                    }
                    if cgImage != nil { break }
                } catch {
                    continue
                }
            }

            guard let cgImage else { return nil }

            guard let destination = CGImageDestinationCreateWithURL(
                thumbnailURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else { return nil }

            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }

            return thumbnailURL
        }
    }

    private func backfillMissingThumbnails() async {
        for item in savedVideos where item.thumbnailURL == nil {
            guard let videoURL = item.url else { continue }
            let thumbnailURL = await generateVideoThumbnail(from: videoURL)
            if let thumbnailURL {
                await MainActor.run {
                    item.thumbnailURL = thumbnailURL
                }
            }
        }
    }

    private func applySavedVideo(_ item: VideoItem) {
        guard let url = item.url else {
            statusMessage = "This saved video has an invalid URL."
            return
        }

        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            statusMessage = "Video file is missing from disk."
            return
        }

        wallpaperManager.setWallpaperVideo(url: url)
        statusMessage = "Applied: \(item.name)"
    }

    private func deleteSavedVideo(_ item: VideoItem) {
        let removedWasActive = item.url == wallpaperManager.selectedVideoURL
        modelContext.delete(item)
        if removedWasActive {
            wallpaperManager.setWallpaperVideo(url: nil)
        }
        statusMessage = "Deleted video: \(item.name)"
    }

}

private struct CurrentSelectedVideoCard: View {
    let videoURL: URL
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VideoThumbnailView(thumbnailURL: nil, videoURL: videoURL)
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(videoURL.deletingPathExtension().lastPathComponent)
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text("Currently selected")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))

            HStack(spacing: 8) {
                Button("Apply") {
                    onApply()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.10), in: Capsule(style: .continuous))
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SavedVideoCard: View {
    let item: VideoItem
    let onApply: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VideoThumbnailView(thumbnailURL: item.thumbnailURL, videoURL: item.url)
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(item.name)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(item.category)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))

            HStack(spacing: 8) {
                Button("Apply") {
                    onApply()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.10), in: Capsule(style: .continuous))

                Button("Delete") {
                    onDelete()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.28), in: Capsule(style: .continuous))
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            onApply()
        }
    }
}

private struct VideoThumbnailView: View {
    let thumbnailURL: URL?
    let videoURL: URL?

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.22, blue: 0.52),
                                Color(red: 0.43, green: 0.18, blue: 0.58)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .task(id: (thumbnailURL?.absoluteString ?? "") + (videoURL?.absoluteString ?? "")) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        if let thumbnailURL,
           let loaded = NSImage(contentsOf: thumbnailURL) {
            await MainActor.run {
                image = loaded
            }
            return
        }

        guard let videoURL,
              videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return
        }

        if let cached = ThumbnailMemoryCache.shared.object(forKey: videoURL.path as NSString) {
            await MainActor.run {
                image = cached
            }
            return
        }

        do {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true

            let probeTimes = [
                CMTime(seconds: 0.0, preferredTimescale: 600),
                CMTime(seconds: 0.35, preferredTimescale: 600),
                CMTime(seconds: 1.0, preferredTimescale: 600)
            ]

            var foundImage: NSImage?

            for time in probeTimes {
                do {
                    let cgImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                        generator.generateCGImageAsynchronously(for: time) { generatedImage, _, error in
                            if let error {
                                continuation.resume(throwing: error)
                                return
                            }

                            guard let generatedImage else {
                                continuation.resume(throwing: NSError(domain: "Livewallspace", code: 1002, userInfo: nil))
                                return
                            }

                            continuation.resume(returning: generatedImage)
                        }
                    }

                    foundImage = NSImage(cgImage: cgImage, size: .zero)
                    break
                } catch {
                    continue
                }
            }

            guard let foundImage else { return }
            ThumbnailMemoryCache.shared.setObject(foundImage, forKey: videoURL.path as NSString)

            await MainActor.run {
                image = foundImage
            }
        }
    }
}

private enum ThumbnailMemoryCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()
}

private struct EmptyLibraryCard: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
            .padding(16)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
