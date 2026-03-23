import Foundation
import SwiftData
import Combine
import AVFoundation

private enum ImportTimeoutError: LocalizedError {
    case exceeded(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .exceeded(let seconds):
            return "Download timed out after \(seconds)s."
        }
    }
}

private let importTimeoutSeconds = 300

private enum ImportValidationError: LocalizedError {
    case missingFile
    case invalidVideoFile

    var errorDescription: String? {
        switch self {
        case .missingFile:
            return "Downloaded file is missing on disk."
        case .invalidVideoFile:
            return "Downloaded file is not a playable video."
        }
    }
}

@MainActor
final class ExploreViewModel: ObservableObject {
    private static var cachedPosts: [MoewallsPost] = []
    private static var cachedFeedPage: Int = 1
    private static var cachedCanLoadMoreFeedPages = true
    private static var cacheTimestamp: Date?
    private static let cacheTTL: TimeInterval = 60 * 20

    @Published var moewallsPosts: [MoewallsPost] = []
    @Published var isLoadingPosts = false
    @Published var isImportingPostIDs: Set<String> = []
    @Published var statusMessage: String?
    @Published var selectedCategory: String = "All" {
        didSet {
            resetPaging()
        }
    }

    @Published private(set) var displayedPostsLimit = 12
    @Published private(set) var isLoadingMorePosts = false

    private let moewalls = MoewallsService()
    private let pageSize = 24
    private var currentFeedPage = 1
    private var canLoadMoreFeedPages = true

    var categories: [String] {
        let all = Set(moewallsPosts.map { $0.category }.filter { !$0.isEmpty })
        return ["All"] + all.sorted()
    }

    var visiblePosts: [MoewallsPost] {
        guard selectedCategory != "All" else { return moewallsPosts }
        return moewallsPosts.filter { $0.category == selectedCategory }
    }

    var pagedVisiblePosts: [MoewallsPost] {
        Array(visiblePosts.prefix(displayedPostsLimit))
    }

    var hasMorePosts: Bool {
        displayedPostsLimit < visiblePosts.count || canLoadMoreFeedPages
    }

    func loadMoewallsPosts(forceRefresh: Bool = false) async {
        guard !isLoadingPosts else { return }

        if !forceRefresh,
           hydrateFromCacheIfFresh() {
            return
        }

        isLoadingPosts = true
        defer { isLoadingPosts = false }

        currentFeedPage = 1
        canLoadMoreFeedPages = true

        do {
            moewallsPosts = try await moewalls.fetchLatestPosts(page: currentFeedPage, limit: pageSize)
            resetPaging()
            statusMessage = "Loaded \(moewallsPosts.count) wallpapers from MoeWalls."
            writeCache()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadMorePosts() async {
        if displayedPostsLimit < visiblePosts.count {
            displayedPostsLimit = min(displayedPostsLimit + 18, visiblePosts.count)
            statusMessage = "Showing \(pagedVisiblePosts.count) of \(visiblePosts.count) wallpapers."
            return
        }

        guard canLoadMoreFeedPages, !isLoadingPosts, !isLoadingMorePosts else {
            return
        }

        await loadNextFeedPage()
    }

    private func loadNextFeedPage() async {
        guard canLoadMoreFeedPages, !isLoadingPosts, !isLoadingMorePosts else {
            return
        }

        isLoadingMorePosts = true
        defer { isLoadingMorePosts = false }

        do {
            let nextPage = currentFeedPage + 1
            let newPosts = try await moewalls.fetchLatestPosts(page: nextPage, limit: pageSize)

            if newPosts.isEmpty {
                canLoadMoreFeedPages = false
                statusMessage = "No more wallpapers available."
                return
            }

            currentFeedPage = nextPage

            var seen = Set(moewallsPosts.map { $0.id })
            let uniqueNew = newPosts.filter { seen.insert($0.id).inserted }
            if uniqueNew.isEmpty {
                canLoadMoreFeedPages = false
                statusMessage = "No more unique wallpapers available."
                return
            }
            moewallsPosts.append(contentsOf: uniqueNew)
            writeCache()

            if displayedPostsLimit < visiblePosts.count {
                displayedPostsLimit = min(displayedPostsLimit + 18, visiblePosts.count)
            }
            statusMessage = "Loaded \(moewallsPosts.count) wallpapers. Showing \(pagedVisiblePosts.count)."
        } catch {
            statusMessage = "Could not load more wallpapers: \(error.localizedDescription)"
        }
    }

    func importMoewallsPost(_ post: MoewallsPost, modelContext: ModelContext) async {
        guard !isImportingPostIDs.contains(post.id) else { return }
        isImportingPostIDs.insert(post.id)
        defer { isImportingPostIDs.remove(post.id) }

        do {
            statusMessage = "Importing \(post.title): downloading (may take a few minutes)..."
            let localURL = try await withTimeout(seconds: importTimeoutSeconds) { [self] in
                try await self.moewalls.downloadWallpaperVideo(from: post) { [weak self] percent, link in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let linkText = link?.absoluteString ?? post.pageURL.absoluteString
                        self.statusMessage = "Importing \(post.title): \(percent)% | \(linkText)"
                    }
                }
            }

            statusMessage = "Importing \(post.title): validating downloaded video..."
            try await validateDownloadedVideo(at: localURL)

            statusMessage = "Importing \(post.title): applying wallpaper..."
            WallpaperManager.shared.setWallpaperVideo(url: localURL)
            WallpaperManager.shared.setUserPaused(false)
            try persistVideoIfNeeded(url: localURL, name: post.title, category: post.category, modelContext: modelContext)
            statusMessage = "Applied wallpaper: \(post.title)"
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func withTimeout<T>(seconds: Int, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw ImportTimeoutError.exceeded(seconds: seconds)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func setLocalVideo(_ url: URL, modelContext: ModelContext) {
        do {
            let importedURL = try ingestLocalVideo(url)
            WallpaperManager.shared.setWallpaperVideo(url: importedURL)
            WallpaperManager.shared.setUserPaused(false)
            try persistVideoIfNeeded(
                url: importedURL,
                name: importedURL.deletingPathExtension().lastPathComponent,
                category: "Local",
                modelContext: modelContext
            )
            statusMessage = "Applied local video: \(importedURL.lastPathComponent)"
        } catch {
            statusMessage = "Local import failed: \(error.localizedDescription)"
        }
    }

    private func ingestLocalVideo(_ sourceURL: URL) throws -> URL {
        let manager = FileManager.default
        let didAccessScopedResource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let appSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport
            .appendingPathComponent("Livewallspace", isDirectory: true)
            .appendingPathComponent("Imported", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let sanitizedBaseName = sourceURL
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension.lowercased()
        let destination = folder.appendingPathComponent("\(sanitizedBaseName)-\(UUID().uuidString).\(ext)")

        try manager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func validateDownloadedVideo(at url: URL) async throws {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw ImportValidationError.missingFile
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw ImportValidationError.invalidVideoFile
        }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else {
            throw ImportValidationError.invalidVideoFile
        }
    }

    private func persistVideoIfNeeded(url: URL, name: String, category: String, modelContext: ModelContext) throws {
        let urlString = url.absoluteString
        let descriptor = FetchDescriptor<VideoItem>(
            predicate: #Predicate { item in
                item.urlString == urlString
            }
        )

        let existing = try modelContext.fetch(descriptor)
        if existing.isEmpty {
            modelContext.insert(VideoItem(url: url, name: name, category: category))
        }
    }

    private func resetPaging() {
        displayedPostsLimit = 12
    }

    private func hydrateFromCacheIfFresh() -> Bool {
        guard let timestamp = Self.cacheTimestamp,
              Date().timeIntervalSince(timestamp) <= Self.cacheTTL,
              !Self.cachedPosts.isEmpty
        else {
            return false
        }

        moewallsPosts = Self.cachedPosts
        currentFeedPage = Self.cachedFeedPage
        canLoadMoreFeedPages = Self.cachedCanLoadMoreFeedPages
        resetPaging()
        statusMessage = "Loaded \(moewallsPosts.count) wallpapers from cache."
        return true
    }

    private func writeCache() {
        Self.cachedPosts = moewallsPosts
        Self.cachedFeedPage = currentFeedPage
        Self.cachedCanLoadMoreFeedPages = canLoadMoreFeedPages
        Self.cacheTimestamp = Date()
    }
}
