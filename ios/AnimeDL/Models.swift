import Foundation

struct AnimeResult: Codable, Identifiable, Hashable {
    let slug: String
    let title: String
    let type: String?
    let episodes: Int?
    let status: String?
    let year: Int?
    let score: Double?
    let poster: String?

    var id: String { slug }

    var subtitle: String {
        [type, year.map(String.init), episodes.flatMap { $0 > 0 ? "\($0) eps" : nil }, status]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct Episode: Codable, Identifiable, Hashable {
    let episode: String
    let title: String
    let duration: String?
    let snapshot: String?
    let audio: String?
    let createdAt: String?

    var id: String { episode }
}

struct DownloadJob: Codable, Identifiable, Hashable {
    let id: String
    let slug: String
    let title: String
    let episode: String
    let resolution: String
    let audio: String
    let status: Status
    let progress: Double
    let message: String
    let file: String?

    enum Status: String, Codable {
        case queued, downloading, done, failed, cancelled
    }

    var isActive: Bool { status == .queued || status == .downloading }
}

struct LibraryShow: Codable, Identifiable, Hashable {
    let name: String
    let episodes: [LibraryEpisode]

    var id: String { name }
}

struct LibraryEpisode: Codable, Identifiable, Hashable {
    let episode: String
    let path: String
    let size: Int64

    var id: String { path }
}

struct ServerStatus: Codable {
    let missing: [String]
    let configured: Bool
    let ua: String
    let downloadDir: String
}

struct DownloadRequest: Encodable {
    let slug: String
    let title: String
    let episodes: [String]
    let resolution: String
    let audio: String
}

struct CloudflareConfig: Encodable {
    let cf: String
    let ua: String
}

struct OK: Decodable {}

/// Wraps a URL so it can drive `.sheet(item:)` / `.fullScreenCover(item:)`.
struct PlayableURL: Identifiable {
    let url: URL
    var id: URL { url }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
