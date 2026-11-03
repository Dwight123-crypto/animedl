import SwiftUI

@main
struct AnimeDLApp: App {
    @StateObject private var api = APIClient()
    @StateObject private var offline = OfflineStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(api)
                .environmentObject(offline)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var api: APIClient
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(0)
            NavigationStack { QueueView() }
                .tabItem { Label("Queue", systemImage: "arrow.down.circle") }.tag(1)
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "play.rectangle.on.rectangle") }.tag(2)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gear") }.tag(3)
        }
        .onAppear { if !api.isConfigured { tab = 3 } }
    }
}

extension View {
    /// Plain text input: no autocorrect or auto-capitalisation (iOS only).
    func plainTextInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Full-screen video on iOS, a sheet elsewhere.
    func player(_ item: Binding<PlayableURL?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { PlayerView(url: $0.url) }
        #else
        sheet(item: item) { PlayerView(url: $0.url) }
        #endif
    }
}
