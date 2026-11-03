import Foundation

/// Episodes copied from the Mac onto the phone, stored in
/// Documents/<Show>/<episode>.mp4 (also visible in the Files app).
@MainActor
final class OfflineStore: ObservableObject {
    struct LocalEpisode: Identifiable, Hashable {
        let show: String
        let episode: String
        let url: URL
        let size: Int64
        var id: URL { url }
    }

    @Published private(set) var episodes: [LocalEpisode] = []
    /// Remote path -> fraction completed, for downloads in flight.
    @Published private(set) var progress: [String: Double] = [:]
    @Published var lastError: String?

    private var observations: [String: NSKeyValueObservation] = [:]
    private let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() { reload() }

    var shows: [(name: String, episodes: [LocalEpisode])] {
        Dictionary(grouping: episodes, by: \.show)
            .map { ($0.key, $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func isSaved(_ episode: LibraryEpisode) -> Bool {
        FileManager.default.fileExists(atPath: destination(for: episode).path)
    }

    func save(_ episode: LibraryEpisode, from url: URL) {
        guard progress[episode.path] == nil else { return }
        let destination = destination(for: episode)
        progress[episode.path] = 0

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            // The temp file is deleted when this handler returns, so move it now.
            var failure = error?.localizedDescription
            if failure == nil, let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                failure = "Server returned HTTP \(code)."
            }
            if failure == nil, let tempURL {
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                } catch {
                    failure = error.localizedDescription
                }
            }
            Task { @MainActor in self?.finish(episode.path, error: failure) }
        }
        observations[episode.path] = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let fraction = p.fractionCompleted
            Task { @MainActor in
                if self?.progress[episode.path] != nil { self?.progress[episode.path] = fraction }
            }
        }
        task.resume()
    }

    func delete(_ episode: LocalEpisode) {
        try? FileManager.default.removeItem(at: episode.url)
        let folder = episode.url.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        episodes = folders.flatMap { folder -> [LocalEpisode] in
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files.filter { $0.pathExtension == "mp4" }.map { file in
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return LocalEpisode(show: folder.lastPathComponent,
                                    episode: file.deletingPathExtension().lastPathComponent,
                                    url: file, size: Int64(size))
            }
        }
        .sorted { ($0.show, Double($0.episode) ?? 0) < ($1.show, Double($1.episode) ?? 0) }
    }

    private func finish(_ path: String, error: String?) {
        progress[path] = nil
        observations[path] = nil
        if let error { lastError = error }
        reload()
    }

    private func destination(for episode: LibraryEpisode) -> URL {
        root.appendingPathComponent(episode.path)  // "<Show>/<n>.mp4", same layout as the Mac
    }
}
