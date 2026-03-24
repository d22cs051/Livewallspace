import Foundation
import SwiftData
import Combine

@Model
final class VideoItem {
    @Attribute(.unique) var urlString: String
    var name: String
    var category: String
    var thumbnailURLString: String?
    var createdAt: Date

    @Relationship(inverse: \Playlist.items)
    var playlists: [Playlist]

    init(url: URL, name: String, category: String, thumbnailURL: URL? = nil, createdAt: Date = .now) {
        self.urlString = url.absoluteString
        self.name = name
        self.category = category
        self.thumbnailURLString = thumbnailURL?.absoluteString
        self.createdAt = createdAt
        self.playlists = []
    }

    var url: URL? {
        URL(string: urlString)
    }

    var thumbnailURL: URL? {
        get {
            guard let thumbnailURLString else { return nil }
            return URL(string: thumbnailURLString)
        }
        set {
            thumbnailURLString = newValue?.absoluteString
        }
    }
}

@Model
final class Playlist {
    var name: String
    var createdAt: Date

    @Relationship
    var items: [VideoItem]

    init(name: String, createdAt: Date = .now, items: [VideoItem] = []) {
        self.name = name
        self.createdAt = createdAt
        self.items = items
    }
}
