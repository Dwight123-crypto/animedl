import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var api: APIClient
    @State private var query = ""
    @State private var results: [AnimeResult] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searched = false

    var body: some View {
        List(results) { anime in
            NavigationLink(value: anime) { AnimeRow(anime: anime) }
        }
        .overlay {
            if loading {
                ProgressView()
            } else if let error {
                ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if results.isEmpty {
                ContentUnavailableView(searched ? "No results" : "Search animepahe",
                                       systemImage: "magnifyingglass",
                                       description: Text(searched ? "Try a different title." : "Type a title and press Search."))
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Anime title")
        .plainTextInput()
        .onSubmit(of: .search) { Task { await search() } }
        .navigationDestination(for: AnimeResult.self) { EpisodesView(anime: $0) }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        error = nil
        defer { loading = false; searched = true }
        do {
            results = try await api.search(q)
        } catch {
            results = []
            self.error = error.localizedDescription
        }
    }
}

struct AnimeRow: View {
    @EnvironmentObject private var api: APIClient
    let anime: AnimeResult

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: api.imageURL(anime.poster)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 50, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(anime.title).font(.headline).lineLimit(2)
                Text(anime.subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
