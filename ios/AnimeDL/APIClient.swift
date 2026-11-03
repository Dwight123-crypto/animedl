import Foundation

/// Talks to server/server.py running on your Mac.
@MainActor
final class APIClient: ObservableObject {
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") }
    }
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "token") }
    }

    init() {
        baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? ""
        token = UserDefaults.standard.string(forKey: "token") ?? ""
    }

    var isConfigured: Bool { !baseURL.isEmpty && !token.isEmpty }

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ErrorBody: Decodable { let error: String }

    // MARK: Endpoints

    func status() async throws -> ServerStatus {
        try await request("GET", "/api/status")
    }

    func search(_ query: String) async throws -> [AnimeResult] {
        try await request("GET", "/api/search", query: ["q": query])
    }

    func episodes(slug: String) async throws -> [Episode] {
        try await request("GET", "/api/episodes", query: ["slug": slug])
    }

    func queue(_ download: DownloadRequest) async throws -> [DownloadJob] {
        try await request("POST", "/api/downloads", body: download)
    }

    func jobs() async throws -> [DownloadJob] {
        try await request("GET", "/api/downloads")
    }

    func cancel(job: DownloadJob) async throws {
        let _: OK = try await request("DELETE", "/api/downloads", query: ["id": job.id])
    }

    func clearFinished() async throws {
        let _: OK = try await request("DELETE", "/api/downloads", query: ["finished": "1"])
    }

    func library() async throws -> [LibraryShow] {
        try await request("GET", "/api/library")
    }

    func delete(_ episode: LibraryEpisode) async throws {
        let _: OK = try await request("DELETE", "/api/library", query: ["path": episode.path])
    }

    /// Server re-reads animepahe's cf_clearance cookie from Chrome on the Mac.
    func refreshCloudflare() async throws -> ServerStatus {
        try await request("POST", "/api/config/refresh")
    }

    func saveCloudflare(cf: String, ua: String) async throws -> ServerStatus {
        try await request("PUT", "/api/config", body: CloudflareConfig(cf: cf, ua: ua))
    }

    /// Streamable URL for a downloaded file. The token goes in the query
    /// because AVPlayer and AsyncImage can't add headers.
    func fileURL(_ episode: LibraryEpisode) -> URL? {
        let encoded = episode.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? episode.path
        return url("/files/" + encoded, query: ["token": token])
    }

    func imageURL(_ remote: String?) -> URL? {
        guard let remote, !remote.isEmpty else { return nil }
        return url("/api/image", query: ["url": remote, "token": token])
    }

    // MARK: Plumbing

    private func url(_ path: String, query: [String: String] = [:]) -> URL? {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard var components = URLComponents(string: base + path) else { return nil }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    private func request<T: Decodable>(_ method: String, _ path: String,
                                       query: [String: String] = [:],
                                       body: (any Encodable)? = nil) async throws -> T {
        guard isConfigured else { throw APIError(message: "Set the server address and token in Settings.") }
        guard let url = url(path, query: query) else { throw APIError(message: "Invalid server address.") }

        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw APIError(message: message ?? "Server returned HTTP \(code).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
