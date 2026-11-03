import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var api: APIClient
    @State private var status: ServerStatus?
    @State private var statusError: String?
    @State private var checking = false
    @State private var cf = ""
    @State private var ua = ""
    @State private var cfMessage: String?
    @State private var refreshing = false

    var body: some View {
        Form {
            Section {
                TextField("http://192.168.1.20:8765", text: $api.baseURL)
                    .plainTextInput()
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif
                SecureField("Token", text: $api.token)
                Button(checking ? "Checking…" : "Test Connection") { Task { await check() } }
                    .disabled(!api.isConfigured || checking)
            } header: {
                Text("Mac server")
            } footer: {
                Text("Both are printed when you start server.py on your Mac.")
            }

            if let statusError {
                Section { Label(statusError, systemImage: "xmark.octagon").foregroundStyle(.red) }
            } else if let status {
                Section("Server status") {
                    row("Connected", ok: true)
                    row(status.missing.isEmpty ? "All tools installed" : "Missing: " + status.missing.joined(separator: ", "),
                        ok: status.missing.isEmpty)
                    row(status.configured ? "Cloudflare cookie set" : "Cloudflare cookie not set", ok: status.configured)
                    LabeledContent("Downloads", value: status.downloadDir).font(.caption)
                }
            }

            Section {
                Button(refreshing ? "Reading Chrome…" : "Refresh from Chrome") { Task { await refreshCloudflare() } }
                    .disabled(!api.isConfigured || refreshing)
                if let cfMessage { Text(cfMessage).font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("Enter manually") {
                    TextField("cf_clearance", text: $cf).plainTextInput()
                    TextField("User-Agent", text: $ua, axis: .vertical).plainTextInput().lineLimit(2...4)
                    Button("Save to Server") { Task { await saveCloudflare() } }
                        .disabled(cf.isEmpty || ua.isEmpty || !api.isConfigured)
                }
            } header: {
                Text("Cloudflare")
            } footer: {
                Text("The server reads animepahe's Cloudflare cookie from Chrome on your Mac automatically, including when it expires. If searches still fail, open animepahe.pw in Chrome on the Mac, pass the check, then tap Refresh from Chrome.")
            }
        }
        .navigationTitle("Settings")
        .task { if api.isConfigured { await check() } }
    }

    private func row(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(ok ? .green : .orange)
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            status = try await api.status()
            statusError = nil
            if ua.isEmpty, let status { ua = status.ua }
        } catch {
            status = nil
            statusError = error.localizedDescription
        }
    }

    private func refreshCloudflare() async {
        refreshing = true
        defer { refreshing = false }
        do {
            status = try await api.refreshCloudflare()
            cfMessage = "Got a fresh cookie from Chrome."
        } catch {
            cfMessage = error.localizedDescription
        }
    }

    private func saveCloudflare() async {
        do {
            status = try await api.saveCloudflare(cf: cf.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  ua: ua.trimmingCharacters(in: .whitespacesAndNewlines))
            cf = ""
            cfMessage = "Saved. Try a search."
        } catch {
            cfMessage = error.localizedDescription
        }
    }
}
