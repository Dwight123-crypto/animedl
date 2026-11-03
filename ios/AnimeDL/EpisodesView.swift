import SwiftUI

struct EpisodesView: View {
    @EnvironmentObject private var api: APIClient
    let anime: AnimeResult

    @State private var episodes: [Episode] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var queueing = false
    @State private var error: String?
    @State private var notice: String?
    @AppStorage("resolution") private var resolution = ""
    @AppStorage("audio") private var audio = ""

    var body: some View {
        List {
            Section {
                Picker("Resolution", selection: $resolution) {
                    Text("Default (1080p)").tag("")
                    Text("1080p").tag("1080")
                    Text("720p").tag("720")
                    Text("360p").tag("360")
                }
                Picker("Audio", selection: $audio) {
                    Text("Default").tag("")
                    Text("Japanese").tag("jpn")
                    Text("English").tag("eng")
                }
            } footer: {
                Text("If the chosen option isn't available, the downloader falls back to 1080p.")
            }

            Section("\(episodes.count) episodes") {
                ForEach(episodes) { ep in
                    Button { toggle(ep) } label: { EpisodeRow(episode: ep, isSelected: selected.contains(ep.id)) }
                        .foregroundStyle(.primary)
                }
            }
        }
        .overlay {
            if loading {
                ProgressView()
            } else if let error {
                ContentUnavailableView("Couldn't load episodes", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            }
        }
        .navigationTitle(anime.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selected.count == episodes.count && !episodes.isEmpty ? "Select None" : "Select All") {
                    selected = selected.count == episodes.count ? [] : Set(episodes.map(\.id))
                }
                .disabled(episodes.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selected.isEmpty {
                Button { Task { await queue() } } label: {
                    Label(queueing ? "Queueing…" : "Download \(selected.count) episode\(selected.count == 1 ? "" : "s")",
                          systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(queueing)
                .padding()
                .background(.bar)
            }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {}
        .task { await load() }
        .refreshable { await load() }
    }

    private func toggle(_ ep: Episode) {
        if selected.contains(ep.id) { selected.remove(ep.id) } else { selected.insert(ep.id) }
    }

    private func load() async {
        do {
            episodes = try await api.episodes(slug: anime.slug)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func queue() async {
        queueing = true
        defer { queueing = false }
        let picked = episodes.map(\.id).filter(selected.contains)  // keep episode order
        do {
            _ = try await api.queue(DownloadRequest(slug: anime.slug, title: anime.title, episodes: picked,
                                                    resolution: resolution, audio: audio))
            selected = []
            notice = "Queued \(picked.count) episode\(picked.count == 1 ? "" : "s"). Track them in the Queue tab."
        } catch {
            notice = error.localizedDescription
        }
    }
}

private struct EpisodeRow: View {
    let episode: Episode
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text("Episode \(episode.episode)").font(.body)
                let details = [episode.title.isEmpty ? nil : episode.title, episode.duration, episode.audio]
                    .compactMap { $0 }.joined(separator: " · ")
                if !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
