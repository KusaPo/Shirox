import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier.hasPrefix(DownloadManager.prefix) else { completionHandler(); return }
        DownloadManager.registerCompletion(identifier, handler: completionHandler)
    }
}

@main struct KairoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: AppStore
    @StateObject private var downloads: DownloadManager
    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        _downloads = StateObject(wrappedValue: DownloadManager(store: store))
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).environmentObject(downloads)
                .tint(Theme.purple)
                .alert("Storage needs attention", isPresented: Binding(get: { store.storageError != nil }, set: { if !$0 { store.storageError = nil } })) {
                    Button("OK") { store.storageError = nil }
                } message: { Text(store.storageError ?? "") }
        }
    }
}

enum Theme {
    static let purple = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(red: 0.78, green: 0.63, blue: 1, alpha: 1) : UIColor(red: 0.44, green: 0.24, blue: 0.80, alpha: 1)
    })
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }.tabItem { Label("Home", systemImage: "house") }
            NavigationStack { DiscoverView() }.tabItem { Label("Discover", systemImage: "safari") }
            NavigationStack { LibraryView() }.tabItem { Label("Library", systemImage: "bookmark") }
            NavigationStack { DownloadsView() }.tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
        }
    }
}

struct Artwork: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            LinearGradient(colors: [Theme.purple.opacity(0.5), .indigo.opacity(0.8)], startPoint: .topTrailing, endPoint: .bottomLeading)
                .overlay { Image(systemName: "sparkles.tv").font(.largeTitle).foregroundStyle(.white.opacity(0.6)) }
        }.accessibilityHidden(true)
    }
}

struct AnimeRow: View {
    let anime: Anime
    var subtitle: String?
    var body: some View {
        HStack(spacing: 14) {
            Artwork(url: anime.cover).frame(width: 58, height: 82).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(anime.title).font(.headline)
                Text(subtitle ?? anime.genres.prefix(2).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

struct ProblemView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.title)
            Text(message).font(.subheadline).multilineTextAlignment(.center)
            Button("Try again", action: retry).buttonStyle(.bordered)
        }.padding(24).frame(maxWidth: .infinity)
    }
}

struct SourceToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink { SourcesView() } label: { Image(systemName: "square.stack.3d.up") }
                .accessibilityLabel("Sources and preferences")
        }
    }
}
