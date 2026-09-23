import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var filter = "All"
    private var items: [Anime] {
        store.state.library.filter { anime in
            let started = store.state.progress.contains { $0.anime.id == anime.id }
            return filter == "All" || (filter == "Watching" ? started : !started)
        }
    }
    var body: some View {
        List {
            Picker("Collection", selection: $filter) { ForEach(["All", "Watching", "Watchlist"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            if items.isEmpty { ContentUnavailableView("Your stories live here", systemImage: "bookmark", description: Text("Save a title or start an episode to add it to your library.")) }
            ForEach(items) { anime in
                NavigationLink { AnimeDetailView(anime: anime, initialEpisode: store.state.progress.filter { $0.anime.id == anime.id }.max(by: { $0.updated < $1.updated })?.episode ?? 1) } label: { AnimeRow(anime: anime) }
                    .swipeActions { Button("Unsave", role: .destructive) { store.toggleSaved(anime) } }
            }
        }.navigationTitle("Your library").toolbar { SourceToolbar() }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var playback: PlaybackRequest?
    @State private var deletion: DownloadRecord?
    private var availableStorage: String {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let bytes = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else { return "Storage unavailable" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " available"
    }
    var body: some View {
        List {
            Section {
                Label(availableStorage, systemImage: "internaldrive")
                Text("Up to two transfers at a time. Wi-Fi preference applies when each new transfer starts.").font(.caption).foregroundStyle(.secondary)
            }
            if store.state.downloads.isEmpty { ContentUnavailableView("Take a story with you", systemImage: "arrow.down.circle", description: Text("Open a title and tap the download button beside an episode.")) }
            Section("Queue") {
                ForEach(store.state.downloads.filter { $0.state != .ready }) { item in row(item) }
            }
            Section("Ready for anywhere") {
                ForEach(store.state.downloads.filter { $0.state == .ready }) { item in row(item) }
            }
        }
        .navigationTitle("Downloads")
        .toolbar { SourceToolbar() }
        .fullScreenCover(item: $playback) { PlayerScreen(request: $0) }
        .confirmationDialog("Remove this download? Watch history will be kept.", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            Button("Remove download", role: .destructive) { if let deletion { downloads.remove(deletion.id) }; deletion = nil }
            Button("Cancel", role: .cancel) { deletion = nil }
        }
    }
    private func row(_ item: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AnimeRow(anime: item.anime, subtitle: "Episode \(item.episode) · \(item.audio.label)")
                Spacer()
                if item.state == .ready {
                    Button { playback = PlaybackRequest(anime: item.anime, episode: item.episode, localURL: item.localURL) } label: { Image(systemName: "play.fill").frame(width: 44, height: 44) }.accessibilityLabel("Play downloaded episode")
                } else if item.state == .downloading || item.state == .resolving || item.state == .queued {
                    Button { downloads.pause(item.id) } label: { Image(systemName: "pause.fill").frame(width: 44, height: 44) }.accessibilityLabel("Pause download")
                } else {
                    Button { downloads.resume(item.id) } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.accessibilityLabel("Resume or retry download")
                }
            }
            if item.state == .downloading { ProgressView(value: item.fraction) }
            Text(item.state == .ready ? "Available offline" : item.state.label).font(.caption).foregroundStyle(Theme.purple)
            if let message = item.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.swipeActions { Button("Remove", role: .destructive) { deletion = item } }
    }
}

struct SourcesView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @State private var sourceLink = ""
    @State private var manifestMessage: String?
    @State private var inspecting = false
    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
            } header: { Text("Appearance") } footer: {
                Text("System follows your device's appearance. Your selection is saved automatically.")
            }
            Section {
                Toggle("Animex", isOn: Binding(get: { store.state.preferences.animexEnabled }, set: { store.state.preferences.animexEnabled = $0; store.save() }))
                Text("Native adapter · Search, episode providers and media URLs. Live playback compatibility must be verified on your device.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Sources") }
            Section {
                TextField("https://…/source.json", text: $sourceLink).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button(inspecting ? "Inspecting…" : "Inspect source link") { Task { await inspect() } }.disabled(inspecting || sourceLink.isEmpty)
                if let manifestMessage { Text(manifestMessage).font(.caption) }
            } header: { Text("Library source links") } footer: { Text("This build can inspect a manifest. Running additional community JavaScript modules is not implemented yet; a link will not be shown as an installed working source.") }
            Section("Playback") {
                Picker("Preferred audio", selection: Binding(get: { store.state.preferences.audio }, set: { store.state.preferences.audio = $0; store.save() })) {
                    ForEach(AudioChoice.allCases) { Text($0.label).tag($0) }
                }
                Text("The native player provides subtitle, audio, AirPlay and picture-in-picture controls when the stream supports them.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Downloads") {
                Toggle("Wi-Fi only for new transfers", isOn: Binding(get: { store.state.preferences.wifiOnly }, set: { store.state.preferences.wifiOnly = $0; store.save() }))
                Text("Existing transfers retain their original network policy. Removing a download keeps your viewing history.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Your data") { Text("Your library, history and download records are saved on this device. Catalog searches contact AniList or the enabled source; media comes from the provider you select.").font(.caption) }
        }.navigationTitle("Sources & preferences")
    }
    @MainActor private func inspect() async {
        guard let url = WebAddress.media(sourceLink.trimmingCharacters(in: .whitespacesAndNewlines)) else { manifestMessage = "Enter a public HTTPS manifest link."; return }
        inspecting = true; manifestMessage = nil
        defer { inspecting = false }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 1_000_000,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["sourceName"] as? String, json["scriptUrl"] is String else { throw KairoError.message("This link did not return a supported source manifest.") }
            manifestMessage = "Found \(name), version \(json["version"] as? String ?? "unknown"). Its JavaScript was not downloaded or executed. Use the built-in Animex adapter for the first device test."
        } catch { manifestMessage = error.localizedDescription }
    }
}
