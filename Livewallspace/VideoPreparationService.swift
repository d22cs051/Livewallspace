import AVFoundation
import Foundation

enum VideoPreparationError: LocalizedError {
    case noCompatibleExportPreset
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCompatibleExportPreset:
            return "No compatible export preset found for this video."
        case .exportFailed(let reason):
            return "Video conversion failed: \(reason)"
        }
    }
}

struct VideoPreparationService {
    func prepareLockScreenVideo(sourceURL: URL, destinationURL: URL) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        let asset = AVURLAsset(url: sourceURL)
        let presetCandidates = [
            AVAssetExportPresetHighestQuality,
            AVAssetExportPreset1920x1080,
            AVAssetExportPreset1280x720,
            AVAssetExportPresetMediumQuality
        ]

        var export: AVAssetExportSession?
        for preset in presetCandidates {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                continue
            }
            if session.supportedFileTypes.contains(.mov) {
                export = session
                break
            }
        }

        guard let export else {
            throw VideoPreparationError.noCompatibleExportPreset
        }

        do {
            try await export.export(to: destinationURL, as: .mov)
        } catch {
            throw VideoPreparationError.exportFailed(error.localizedDescription)
        }
    }
}
