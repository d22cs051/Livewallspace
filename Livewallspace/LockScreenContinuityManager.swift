import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Combine

@MainActor
final class LockScreenContinuityManager: ObservableObject {
    static let shared = LockScreenContinuityManager()

    @Published private(set) var isEnabled: Bool

    private let defaultsKey = "LockScreenContinuityEnabled"
    private let fileManager = FileManager.default

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: defaultsKey)
    }

    func setEnabled(_ enabled: Bool, sourceVideoURL: URL?) async throws -> String {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: defaultsKey)

        guard enabled else {
            return "Lock screen continuity disabled."
        }

        guard let sourceVideoURL else {
            return "Enabled lock screen continuity. Pick a video to generate the lock screen image."
        }

        let outputURL = try await generateSnapshot(from: sourceVideoURL)
        try applySnapshotToDesktop(outputURL)
        return "Lock screen continuity enabled. Desktop picture updated from current video frame."
    }

    func syncFromCurrentVideoIfNeeded(_ sourceVideoURL: URL?) async {
        guard isEnabled, let sourceVideoURL else { return }

        do {
            let outputURL = try await generateSnapshot(from: sourceVideoURL)
            try applySnapshotToDesktop(outputURL)
        } catch {
            // Ignore failures here; settings flow surfaces explicit errors to the user.
        }
    }

    private func generateSnapshot(from sourceVideoURL: URL) async throws -> URL {
        let outputURL = try lockScreenSnapshotURL()

        try await Task.detached(priority: .utility) {
            try Self.extractFrameImage(from: sourceVideoURL, outputURL: outputURL)
        }.value

        return outputURL
    }

    private func lockScreenSnapshotURL() throws -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport
            .appendingPathComponent("Livewallspace", isDirectory: true)
            .appendingPathComponent("LockScreen", isDirectory: true)

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("lockscreen-frame.png", isDirectory: false)
    }

    private func applySnapshotToDesktop(_ imageURL: URL) throws {
        for screen in NSScreen.screens {
            let existingOptions = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: existingOptions)
        }
    }

    private nonisolated static func extractFrameImage(from videoURL: URL, outputURL: URL) throws {
        let asset = AVURLAsset(url: videoURL)
        let pickTimeSeconds: Double = 1.0

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let semaphore = DispatchSemaphore(value: 0)
        var generatedImage: CGImage?
        var generationError: Error?

        generator.generateCGImageAsynchronously(
            for: CMTime(seconds: pickTimeSeconds, preferredTimescale: 600)
        ) { cgImage, _, error in
            generatedImage = cgImage
            generationError = error
            semaphore.signal()
        }

        semaphore.wait()

        if let generationError {
            throw generationError
        }

        guard let cgImage = generatedImage else {
            throw NSError(domain: "Livewallspace", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to generate lock screen frame image."
            ])
        }

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "Livewallspace", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create image destination for lock screen snapshot."
            ])
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Livewallspace", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to write lock screen snapshot image."
            ])
        }
    }
}
