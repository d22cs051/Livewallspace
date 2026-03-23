import AppKit
import AVFoundation
import CryptoKit
import CoreMedia
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class SystemWallpaperManifestIntegrationManager {
    static let shared = SystemWallpaperManifestIntegrationManager()

    private let fileManager = FileManager.default
    private let preparationService = VideoPreparationService()
    private let appPrefix = "livewallspace-"

    private init() {}

    func syncCurrentVideoIfNeeded(_ sourceVideoURL: URL?) async {
        guard let sourceVideoURL else { return }
        do {
            let message = try await registerCurrentVideo(sourceVideoURL)
            postSyncStatus(message: message)
        } catch {
            postSyncStatus(message: "System Wallpaper sync failed: \(error.localizedDescription)")
        }
    }

    func registerCurrentVideo(_ sourceVideoURL: URL) async throws -> String {
        let folders = try wallpaperFolders()
        let stagedVideoURL = try await stageVideoForSystem(sourceVideoURL)
        let displayName = sourceVideoURL.deletingPathExtension().lastPathComponent

        let assetID = stableAssetIdentifier(for: displayName)
        let fileStem = assetID
        let wallpaperVideoURL = folders.videos.appendingPathComponent("\(fileStem).mov", isDirectory: false)
        let wallpaperThumbnailURL = folders.thumbnails.appendingPathComponent("\(fileStem).png", isDirectory: false)

        if fileManager.fileExists(atPath: wallpaperVideoURL.path) {
            try fileManager.removeItem(at: wallpaperVideoURL)
        }

        if fileManager.fileExists(atPath: wallpaperThumbnailURL.path) {
            try fileManager.removeItem(at: wallpaperThumbnailURL)
        }

        try fileManager.copyItem(at: stagedVideoURL, to: wallpaperVideoURL)
        do {
            try await generateThumbnail(from: wallpaperVideoURL, to: wallpaperThumbnailURL)
        } catch {
            try generateFallbackThumbnail(for: wallpaperVideoURL, to: wallpaperThumbnailURL)
        }

        guard fileManager.fileExists(atPath: wallpaperThumbnailURL.path) else {
            throw NSError(domain: "Livewallspace", code: 2006, userInfo: [
                NSLocalizedDescriptionKey: "Generated thumbnail is missing at \(wallpaperThumbnailURL.path)."
            ])
        }

        var manifest = try loadManifest(at: folders.manifest)
        upsertLivewallspaceAsset(
            manifest: &manifest,
            assetID: assetID,
            displayName: displayName,
            videoURL: wallpaperVideoURL,
            thumbnailURL: wallpaperThumbnailURL
        )

        try saveManifest(manifest, to: folders.manifest)
        try restartWallpaperServices()

        return "Registered Livewallspace wallpaper in System Settings."
    }

    private func postSyncStatus(message: String) {
        NotificationCenter.default.post(
            name: .livewallspaceSystemCatalogSyncStatus,
            object: nil,
            userInfo: ["message": message]
        )
    }

    private func stageVideoForSystem(_ sourceVideoURL: URL) async throws -> URL {
        let cacheFolder = try appCacheFolder()
        let stagedURL = cacheFolder.appendingPathComponent("prepared-\(UUID().uuidString).mov", isDirectory: false)

        if fileManager.fileExists(atPath: stagedURL.path) {
            try fileManager.removeItem(at: stagedURL)
        }

        try await preparationService.prepareLockScreenVideo(sourceURL: sourceVideoURL, destinationURL: stagedURL)
        return stagedURL
    }

    private func appCacheFolder() throws -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport
            .appendingPathComponent("Livewallspace", isDirectory: true)
            .appendingPathComponent("SystemWallpaper", isDirectory: true)

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func wallpaperFolders() throws -> (root: URL, manifest: URL, thumbnails: URL, videos: URL) {
        let root = realUserHomeDirectoryURL()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.apple.wallpaper", isDirectory: true)
            .appendingPathComponent("aerials", isDirectory: true)

        let manifestFolder = root.appendingPathComponent("manifest", isDirectory: true)
        let thumbnails = root.appendingPathComponent("thumbnails", isDirectory: true)
        let videos = root.appendingPathComponent("videos", isDirectory: true)

        try fileManager.createDirectory(at: manifestFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: videos, withIntermediateDirectories: true)

        let manifest = manifestFolder.appendingPathComponent("entries.json", isDirectory: false)
        return (root, manifest, thumbnails, videos)
    }

    private func realUserHomeDirectoryURL() -> URL {
        guard let pwd = getpwuid(getuid()),
              let homeCString = pwd.pointee.pw_dir
        else {
            return fileManager.homeDirectoryForCurrentUser
        }

        return URL(fileURLWithPath: String(cString: homeCString), isDirectory: true)
    }

    private func loadManifest(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            throw NSError(domain: "Livewallspace", code: 2001, userInfo: [
                NSLocalizedDescriptionKey: "Wallpaper manifest not found. Open Wallpaper settings once and try again."
            ])
        }

        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw NSError(domain: "Livewallspace", code: 2002, userInfo: [
                NSLocalizedDescriptionKey: "Wallpaper manifest format is invalid."
            ])
        }

        return dictionary
    }

    private func saveManifest(_ manifest: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try data.write(to: url, options: .atomic)
    }

    private func stableAssetIdentifier(for _: String) -> String {
        // Keep one persistent custom-wallpaper slot so System Settings selection survives new applies.
        let normalized = "livewallspace-active-wallpaper-slot"
        let digest = SHA256.hash(data: Data(normalized.utf8))
        var bytes = Array(digest.prefix(16))

        // Mark as RFC 4122 variant + version 5 style UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let hex = bytes.map { String(format: "%02X", $0) }
        return [
            hex[0...3].joined(),
            hex[4...5].joined(),
            hex[6...7].joined(),
            hex[8...9].joined(),
            hex[10...15].joined()
        ].joined(separator: "-")
    }

    private func upsertLivewallspaceAsset(
        manifest: inout [String: Any],
        assetID: String,
        displayName: String,
        videoURL: URL,
        thumbnailURL: URL
    ) {
        var categories = manifest["categories"] as? [[String: Any]] ?? []
        let assets = manifest["assets"] as? [[String: Any]] ?? []

        let filteredAssets = assets.filter { asset in
            guard let shotID = asset["shotID"] as? String else { return true }
            return !shotID.hasPrefix(appPrefix)
        }

        let categoryIndex = categories.firstIndex { category in
            let localizedName = (category["localizedNameKey"] as? String) ?? ""
            return localizedName.lowercased().contains("custom")
        }

        let categoryID: String
        let subcategoryID: String

        if let categoryIndex {
            categoryID = (categories[categoryIndex]["id"] as? String) ?? UUID().uuidString

            let existingSubcategories = categories[categoryIndex]["subcategories"] as? [[String: Any]] ?? []
            if let firstSubcategory = existingSubcategories.first,
               let id = firstSubcategory["id"] as? String {
                subcategoryID = id
            } else {
                subcategoryID = UUID().uuidString
            }

            categories[categoryIndex]["id"] = categoryID
            categories[categoryIndex]["localizedNameKey"] = "Custom Videos"
            categories[categoryIndex]["localizedDescriptionKey"] = "Custom Videos"
            categories[categoryIndex]["previewImage"] = thumbnailURL.absoluteString
            categories[categoryIndex]["representativeAssetID"] = assetID
            categories[categoryIndex]["subcategories"] = [[
                "id": subcategoryID,
                "localizedNameKey": "Custom Videos",
                "localizedDescriptionKey": "Custom Videos",
                "previewImage": thumbnailURL.absoluteString,
                "preferredOrder": 0,
                "representativeAssetID": assetID
            ]]
        } else {
            categoryID = UUID().uuidString
            subcategoryID = UUID().uuidString

            categories.append([
                "id": categoryID,
                "localizedNameKey": "Custom Videos",
                "localizedDescriptionKey": "Custom Videos",
                "previewImage": thumbnailURL.absoluteString,
                "preferredOrder": maxCategoryOrder(in: categories) + 1,
                "representativeAssetID": assetID,
                "subcategories": [[
                    "id": subcategoryID,
                    "localizedNameKey": "Custom Videos",
                    "localizedDescriptionKey": "Custom Videos",
                    "previewImage": thumbnailURL.absoluteString,
                    "preferredOrder": 0,
                    "representativeAssetID": assetID
                ]]
            ])
        }

        var updatedAssets = filteredAssets
        updatedAssets.append([
            "id": assetID,
            "showInTopLevel": true,
            "shotID": "\(appPrefix)\(assetID)",
            "localizedNameKey": displayName,
            "accessibilityLabel": displayName,
            "previewImage": thumbnailURL.absoluteString,
            "previewImage-900x580": "",
            "pointsOfInterest": [:],
            "includeInShuffle": false,
            "url-4K-SDR-240FPS": videoURL.absoluteString,
            "subcategories": [subcategoryID],
            "preferredOrder": maxAssetOrder(in: updatedAssets) + 1,
            "categories": [categoryID]
        ])

        manifest["categories"] = categories
        manifest["assets"] = updatedAssets
    }

    private func maxCategoryOrder(in categories: [[String: Any]]) -> Int {
        categories.compactMap { $0["preferredOrder"] as? Int }.max() ?? 0
    }

    private func maxAssetOrder(in assets: [[String: Any]]) -> Int {
        assets.compactMap { $0["preferredOrder"] as? Int }.max() ?? 0
    }

    private func generateThumbnail(from videoURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            generator.generateCGImageAsynchronously(for: CMTime(seconds: 1.0, preferredTimescale: 600)) { cgImage, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let cgImage else {
                    continuation.resume(throwing: NSError(domain: "Livewallspace", code: 2008, userInfo: [
                        NSLocalizedDescriptionKey: "Could not generate thumbnail frame from video."
                    ]))
                    return
                }

                continuation.resume(returning: cgImage)
            }
        }

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "Livewallspace", code: 2003, userInfo: [
                NSLocalizedDescriptionKey: "Could not create thumbnail destination."
            ])
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Livewallspace", code: 2004, userInfo: [
                NSLocalizedDescriptionKey: "Could not finalize thumbnail file."
            ])
        }
    }

    private func generateFallbackThumbnail(for videoURL: URL, to outputURL: URL) throws {
        let image = NSWorkspace.shared.icon(forFile: videoURL.path)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            throw NSError(domain: "Livewallspace", code: 2007, userInfo: [
                NSLocalizedDescriptionKey: "Could not produce fallback thumbnail."
            ])
        }

        try pngData.write(to: outputURL, options: .atomic)
    }

    private func restartWallpaperServices() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = [
            "WallpaperAgent",
            "WallpaperAerialsExtension",
            "WallpaperImageExtension",
            "WallpaperLegacyExtension"
        ]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw NSError(domain: "Livewallspace", code: 2005, userInfo: [
                NSLocalizedDescriptionKey: "Failed to restart Wallpaper services: \(error.localizedDescription)"
            ])
        }
    }
}

extension Notification.Name {
    static let livewallspaceSystemCatalogSyncStatus = Notification.Name("LivewallspaceSystemCatalogSyncStatus")
}
