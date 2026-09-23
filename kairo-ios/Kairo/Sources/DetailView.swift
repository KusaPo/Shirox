import SwiftUI

struct EpisodeAction: Identifiable {
    var id = UUID()
    var episode: Int
    var download: Bool
}

struct AnimeDetailView: View {
    let anime: Anime
    var initialEpisode: Int = 1
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var resolved: Anime?
    @State private var error: String?
    @State private var busy = false
    @State private var reload = UUID()
    @State private var action: EpisodeAction?
    @State private var playback: PlaybackRequest?
    @State private var pendingPlayback: PlaybackRequest?
    @State private var pendingQueued = false
    @State private var customEpisode = 1
    @State private var queued = false
    private var title: Anime { resolved ?? anime }
    var body: some View {
        List {
            Section {
                Artwork(url: title.banner ?? title.cover).frame(height: 225).clipped().listRowInsets(EdgeInsets())
                Text(title.title).font(.title.bold())
                if !title.genres.isEmpty { Text(title.genres.prefix(3).joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary) }
                HStack {
                    Button { action = EpisodeAction(episode: initialEpisode, download: false) } label: {
                        Label(store.progress(title, episode: initialEpisode) == nil ? "Watch episode \(initialEpisode)" : "Resume episode \(initialEpisode)", systemImage: "play.fill")
                    }.buttonStyle(.borderedProminent).disabled(busy || resolved == nil || !store.state.preferences.animexEnabled)
                    Spacer()
                    Button { store.toggleSaved(title) } label: { Image(systemName: store.state.library.contains(where: { $0.id == title.id }) ? "bookmark.fill" : "bookmark") }.buttonStyle(.bordered).accessibilityLabel("Toggle saved title")
                }
                if !title.synopsis.isEmpty { Text(title.synopsis).font(.subheadline).foregroundStyle(.secondary) }
                Label("Source: Animex", systemImage: "square.stack.3d.up").font(.subheadline)
            }
            if busy { ProgressView("Matching this title to Animex…") }
            if let error { ProblemView(message: error) { reload = UUID() } }
            if resolved != nil {
                Section {
                    if let count = title.episodeCount, count > 0 {
                        ForEach(1...min(count, 5000), id: \.self) { episode in episodeRow(episode) }
                    } else {
                        Text("This source did not provide an episode count. Choose an episode number to check availability.").font(.caption)
                        Stepper("Episode \(customEpisode)", value: $customEpisode, in: 1...5000)
                        episodeRow(customEpisode)
                    }
                } header: { Text("Episodes") } footer: { Text("Listed episode counts do not guarantee stream availability in both languages.") }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reload) {
            busy = true; error = nil
            defer { busy = false }
            do {
                guard store.state.preferences.animexEnabled else { throw KairoError.message("Animex is disabled. Enable it in Sources to find episodes.") }
                resolved = try await CatalogAPI.shared.resolve(anime)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .sheet(item: $action, onDismiss: {
            playback = pendingPlayback
            pendingPlayback = nil
            queued = pendingQueued
            pendingQueued = false
        }) { selection in
            StreamPicker(anime: title, episode: selection.episode, forDownload: selection.download) { stream, batch in
                if selection.download {
                    let last = min(selection.episode + (batch ? 2 : 0), title.episodeCount ?? selection.episode)
                    for number in selection.episode...max(selection.episode, last) {
                        downloads.enqueue(title, episode: number, audio: stream.audio, provider: stream.provider)
                    }
                    pendingQueued = true
                } else {
                    pendingPlayback = PlaybackRequest(anime: title, episode: selection.episode, stream: stream)
                }
                action = nil
            }
        }
        .fullScreenCover(item: $playback) { PlayerScreen(request: $0) }
        .alert("Added to Downloads", isPresented: $queued) { Button("OK", role: .cancel) {} } message: { Text("The queue will check the selected provider and prepare your offline file. Existing items are not duplicated.") }
    }
    private func episodeRow(_ episode: Int) -> some View {
        HStack {
            Button { action = EpisodeAction(episode: episode, download: false) } label: {
                HStack {
                    Text(String(format: "%02d", episode)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28)
                    VStack(alignment: .leading) {
                        Text("Episode \(episode)")
                        if let progress = store.progress(title, episode: episode) {
                            Text(progress.finished ? "Watched" : "Continue at \(Int(progress.seconds / 60)) min").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { action = EpisodeAction(episode: episode, download: true) } label: { Image(systemName: "arrow.down.to.line").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("Download episode \(episode)")
        }
    }
}

struct StreamPicker: View {
    let anime: Anime
    let episode: Int
    let forDownload: Bool
    let choose: (StreamOption, Bool) -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var audio: AudioChoice = .sub
    @State private var streams: [StreamOption] = []
    @State private var busy = true
    @State private var error: String?
    @State private var batch = false
    @State private var retry = UUID()
    @State private var initialized = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(anime.title).font(.headline)
                    Text("Episode \(episode)").foregroundStyle(.secondary)
                    Picker("Audio", selection: $audio) { ForEach(AudioChoice.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                    if forDownload {
                        Text("Quality: source default. Exact resolution selection is not yet supported.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Include next 2 episodes", isOn: $batch).disabled(anime.episodeCount == nil)
                    }
                }
                if busy { ProgressView("Finding playable streams…") }
                else if let error { ProblemView(message: error) { retry = UUID() } }
                else {
                    Section("Choose a provider") {
                        ForEach(streams) { stream in
                            Button { store.state.preferences.audio = audio; store.save(); choose(stream, batch) } label: {
                                HStack { Label(stream.label, systemImage: forDownload ? "arrow.down.circle" : "play.circle"); Spacer(); Text(stream.isHLS ? "HLS" : "MP4").font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 7)
                            }
                        }
                    }
                    if forDownload { Text("Embedded subtitles are included when available. External subtitle files are not supported in this first build.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(forDownload ? "Save for offline" : "Playback source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if !initialized { audio = store.state.preferences.audio; initialized = true } }
            .task(id: audio.rawValue + retry.uuidString) {
                busy = true; error = nil; streams = []
                do {
                    let found = try await CatalogAPI.shared.streams(anime, episode: episode, audio: audio)
                    try Task.checkCancellation()
                    streams = found; busy = false
                } catch is CancellationError { }
                catch { if !Task.isCancelled { self.error = error.localizedDescription; busy = false } }
            }
        }.presentationDetents([.large])
    }
}
