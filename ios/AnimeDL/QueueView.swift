import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var api: APIClient
    @State private var jobs: [DownloadJob] = []
    @State private var error: String?

    var body: some View {
        List {
            ForEach(jobs) { job in
                JobRow(job: job)
                    .swipeActions {
                        Button(job.isActive ? "Cancel" : "Remove", role: .destructive) {
                            Task { await act { try await api.cancel(job: job) } }
                        }
                        if job.status == .failed || job.status == .cancelled {
                            Button("Retry") { Task { await act { try await retry(job) } } }.tint(.blue)
                        }
                    }
            }
        }
        .overlay {
            if let error {
                ContentUnavailableView("Can't reach server", systemImage: "wifi.exclamationmark",
                                       description: Text(error))
            } else if jobs.isEmpty {
                ContentUnavailableView("Nothing queued", systemImage: "arrow.down.circle",
                                       description: Text("Pick episodes in Search to download them on your Mac."))
            }
        }
        .navigationTitle("Queue")
        .toolbar {
            Button("Clear Finished") { Task { await act { try await api.clearFinished() } } }
                .disabled(!jobs.contains { !$0.isActive })
        }
        .task {
            // Poll while the tab is visible.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refresh() async {
        do {
            jobs = try await api.jobs().reversed()  // newest first
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func retry(_ job: DownloadJob) async throws {
        _ = try await api.queue(DownloadRequest(slug: job.slug, title: job.title, episodes: [job.episode],
                                                resolution: job.resolution, audio: job.audio))
        try await api.cancel(job: job)  // removes the old failed entry
    }

    private func act(_ action: () async throws -> Void) async {
        do { try await action() } catch { self.error = error.localizedDescription }
        await refresh()
    }
}

private struct JobRow: View {
    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.title).font(.headline).lineLimit(1)
                Spacer()
                Text("Ep \(job.episode)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            if job.status == .downloading {
                ProgressView(value: job.progress, total: 100)
            }
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(job.message.isEmpty ? job.status.rawValue.capitalized : job.message)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch job.status {
        case .queued: "clock"
        case .downloading: "arrow.down.circle"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var color: Color {
        switch job.status {
        case .done: .green
        case .failed: .orange
        default: .secondary
        }
    }
}
