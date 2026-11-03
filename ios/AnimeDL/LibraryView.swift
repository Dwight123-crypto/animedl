import AVKit
import SwiftUI

struct LibraryView: View {
    enum Source: String, CaseIterable { case mac = "On Mac", phone = "On iPhone" }

    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var offline: OfflineStore
    @State private var source = Source.mac
    @State private var shows: [LibraryShow] = []
    @State private var error: String?
    @State private var playing: PlayableURL?

    var body: some View {
        List {
            Picker("Source", selection: $source) {
                ForEach(Source.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            switch source {
            case .mac: macList
            case .phone: phoneList
            }
        }
        .navigationTitle("Library")
        .player($playing)
        .task(id: source) { if source == .mac { await load() } else { offline.reload() } }
        .refreshable { if source == .mac { await load() } else { offline.reload() } }
        .alert(offline.lastError ?? "",
               isPresented: Binding(get: { offline.lastError != nil }, set: { if !$0 { offline.lastError = nil } })) {}
    }

    @ViewBuilder private var macList: some View {
        if let error {
            Text(error).foregroundStyle(.secondary)
        } else if shows.isEmpty {
            Text("No downloads on your Mac yet.").foregroundStyle(.secondary)
        }
        ForEach(shows) { show in
            Section(show.name) {
                ForEach(show.episodes) { ep in
                    MacEpisodeRow(episode: ep, play: { playing = api.fileURL(ep).map(PlayableURL.init) })
                        .swipeActions {
                            Button("Delete", role: .destructive) { Task { await delete(ep) } }
                        }
                }
            }
        }
    }

    @ViewBuilder private var phoneList: some View {
        if offline.episodes.isEmpty {
            Text("Nothing saved on this iPhone. In “On Mac”, tap ↓ next to an episode to save it for offline viewing.")
                .foregroundStyle(.secondary)
        }
        ForEach(offline.shows, id: \.name) { show in
            Section(show.name) {
                ForEach(show.episodes) { ep in
                    Button { playing = PlayableURL(url: ep.url) } label: {
                        HStack {
                            Label("Episode \(ep.episode)", systemImage: "play.circle")
                            Spacer()
                            Text(formatBytes(ep.size)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { offline.delete(ep) }
                    }
                }
            }
        }
    }

    private func load() async {
        do {
            shows = try await api.library()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ ep: LibraryEpisode) async {
        do { try await api.delete(ep) } catch { self.error = error.localizedDescription }
        await load()
    }
}

private struct MacEpisodeRow: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var offline: OfflineStore
    let episode: LibraryEpisode
    let play: () -> Void

    var body: some View {
        HStack {
            Button(action: play) {
                Label("Episode \(episode.episode)", systemImage: "play.circle")
            }
            Spacer()
            Text(formatBytes(episode.size)).font(.caption).foregroundStyle(.secondary)
            if let fraction = offline.progress[episode.path] {
                ProgressView(value: fraction).frame(width: 44)
            } else if offline.isSaved(episode) {
                Image(systemName: "iphone").foregroundStyle(.green)
            } else if let url = api.fileURL(episode) {
                Button { offline.save(episode, from: url) } label: {
                    Image(systemName: "arrow.down.to.line.circle")
                }
            }
        }
        .buttonStyle(.borderless)  // let both buttons in the row be tapped separately
    }
}

struct PlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title).symbolRenderingMode(.hierarchical)
                }
                .padding()
            }
            .onAppear {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                player.play()
            }
            .onDisappear { player.pause() }
    }
}
