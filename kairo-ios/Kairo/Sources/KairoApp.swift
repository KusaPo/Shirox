import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier.hasPrefix(DownloadManager.prefix) else { completionHandler(); return }
        DownloadManager.registerCompletion(identifier, handler: completionHandler)
    }
}

@main struct KairoApp: App {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
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
                .preferredColorScheme(appearance.colorScheme)
                .alert("Storage needs attention", isPresented: Binding(get: { store.storageError != nil }, set: { if !$0 { store.storageError = nil } })) {
                    Button("OK") { store.storageError = nil }
                } message: { Text(store.storageError ?? "") }
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
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

enum KairoTab: Hashable { case home, discover, library, downloads, settings }

struct RootView: View {
    @State private var selectedTab: KairoTab = .home
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(selectedTab: $selectedTab) }
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(KairoTab.home)
            NavigationStack { DiscoverView() }
                .tabItem { Label("Discover", systemImage: "magnifyingglass") }.tag(KairoTab.discover)
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }.tag(KairoTab.library)
            NavigationStack { DownloadsView() }
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }.tag(KairoTab.downloads)
            NavigationStack { SourcesView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(KairoTab.settings)
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

@MainActor final class ArtworkMemoryCache {
    static let shared = ArtworkMemoryCache()
    private let images = NSCache<NSURL, UIImage>()
    init() { images.totalCostLimit = 80 * 1_024 * 1_024 }
    func cached(_ url: URL) -> UIImage? { images.object(forKey: url as NSURL) }
    func load(_ url: URL) async throws -> UIImage {
        if let image = cached(url) { return image }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 12_000_000, let image = UIImage(data: data) else {
            throw KairoError.message("Artwork could not be loaded.")
        }
        images.setObject(image, forKey: url as NSURL, cost: data.count)
        return image
    }
    func clear() { images.removeAllObjects(); URLCache.shared.removeAllCachedResponses() }
}

struct Artwork: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Theme.purple.opacity(0.25), .indigo.opacity(0.35)], startPoint: .topTrailing, endPoint: .bottomLeading)
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(systemName: "sparkles.tv").font(.title2).foregroundStyle(Theme.purple)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: url) {
            image = url.flatMap { ArtworkMemoryCache.shared.cached($0) }
            guard let url else { return }
            image = try? await ArtworkMemoryCache.shared.load(url)
        }
        .accessibilityHidden(true)
    }
}

// Wide banners get a wide frame, instead of being enlarged into a tall card.
// When only a portrait poster exists, keep it intact over a full-bleed backdrop.
struct AnimeArtwork: View {
    let anime: Anime
    var body: some View {
        GeometryReader { geometry in
            if let banner = anime.banner {
                Artwork(url: banner)
            } else {
                ZStack {
                    Artwork(url: anime.cover).blur(radius: 18)
                    Color.black.opacity(0.2)
                    Artwork(url: anime.cover, contentMode: .fit)
                        .frame(width: geometry.size.height * 2 / 3)
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }
        }
    }
}

/// Keep a complete portrait cover visible while its blurred colors fill a differently shaped card.
struct PosterArtwork: View {
    let url: URL?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Artwork(url: url).blur(radius: 14)
                Color.black.opacity(0.16)
                Artwork(url: url, contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.accessibilityHidden(true)
    }
}

struct AnimeRow: View {
    let anime: Anime
    var subtitle: String?
    var body: some View {
        HStack(spacing: 14) {
            PosterArtwork(url: anime.cover).frame(width: 58, height: 82).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(anime.title).font(.headline)
                Text(subtitle ?? anime.genres.prefix(2).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

struct EpisodeWatchProgress: View {
    let progress: WatchProgress?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress {
                Text(progress.summary).font(.caption).foregroundStyle(.secondary)
                ProgressView(value: progress.finished ? 1 : progress.fraction).tint(Theme.purple)
                if !progress.finished { Text(progress.remainingLabel).font(.caption2).foregroundStyle(.secondary) }
            } else {
                Text("Not started").font(.caption).foregroundStyle(.secondary)
            }
        }
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
