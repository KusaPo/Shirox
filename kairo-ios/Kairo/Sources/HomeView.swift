import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !store.state.trending.isEmpty {
                    TrendingCarousel(items: store.state.trending)
                    if let error { Text("Showing saved trending titles. \(error)").font(.caption).foregroundStyle(.secondary) }
                    if let date = store.state.trendingUpdated { Text("Trending on AniList · Updated \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                } else if busy { ProgressView("Loading trending anime…").frame(maxWidth: .infinity).padding(40) }
                else if let error { ProblemView(message: error) { Task { await load() } } }
                if !store.continuing.isEmpty {
                    Text("Pick up where you left off").font(.title3.bold())
                    ForEach(store.continuing.prefix(5)) { progress in
                        NavigationLink { AnimeDetailView(anime: progress.anime, initialEpisode: progress.episode) } label: {
                            VStack(alignment: .leading) {
                                AnimeRow(anime: progress.anime, subtitle: "Episode \(progress.episode) · \(max(0, Int((progress.duration - progress.seconds) / 60))) min left")
                                ProgressView(value: min(1, progress.seconds / max(1, progress.duration)))
                            }.padding().background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your next watch starts here").font(.title3.bold())
                        Text("Choose a trending title or search Animex in Discover. Your viewing progress will appear here.").foregroundStyle(.secondary)
                        NavigationLink("Sources & setup") { SourcesView() }.buttonStyle(.bordered)
                    }.padding().background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                }
            }.padding()
        }
        .background(Theme.background)
        .navigationTitle("kairo")
        .toolbar { SourceToolbar() }
        .task { if store.state.trendingUpdated.map({ Date().timeIntervalSince($0) > 3600 }) ?? true { await load() } }
        .refreshable { await load() }
    }
    @MainActor private func load() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            store.state.trending = Array(try await CatalogAPI.shared.trending().prefix(10))
            store.state.trendingUpdated = Date()
            store.save()
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

struct TrendingCarousel: View {
    let items: [Anime]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: AppStore
    @State private var index = 0
    @State private var paused = false
    @State private var visible = true
    private var rotate: Bool { !paused && !reduceMotion && !voiceOver && visible && scenePhase == .active && items.count > 1 }
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { rank, anime in
                    VStack(spacing: 0) {
                        Artwork(url: anime.banner ?? anime.cover).frame(height: 190)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("TRENDING ANIME").font(.caption.weight(.semibold)).tracking(1.5)
                                Spacer()
                                Text(String(format: "%02d", rank + 1)).font(.headline.monospacedDigit())
                            }.foregroundStyle(Theme.purple)
                            Text(anime.title).font(.system(.title2, design: .serif)).lineLimit(2).minimumScaleFactor(0.8)
                            Text(anime.genres.prefix(2).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            HStack {
                                NavigationLink { AnimeDetailView(anime: anime) } label: { Label("View anime", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 7) }.buttonStyle(.borderedProminent)
                                Button { store.toggleSaved(anime) } label: {
                                    Image(systemName: store.state.library.contains(where: { $0.id == anime.id }) ? "checkmark" : "plus").frame(width: 44, height: 44)
                                }.buttonStyle(.bordered).accessibilityLabel("Toggle saved title")
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    }.background(Theme.surface).tag(rank)
                }
            }.tabViewStyle(.page(indexDisplayMode: .never)).frame(height: 410)
                .simultaneousGesture(DragGesture(minimumDistance: 15).onChanged { _ in paused = true })
            HStack {
                Button { paused = true; move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Previous trending anime")
                Text("\(index + 1) / \(items.count)").font(.caption.monospacedDigit())
                Spacer()
                Button { paused.toggle() } label: { Image(systemName: paused || reduceMotion || voiceOver ? "play.fill" : "pause.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel(paused ? "Resume automatic slides" : "Pause automatic slides").disabled(reduceMotion || voiceOver)
                Button { paused = true; move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("Next trending anime")
            }.padding(.horizontal, 8).background(Theme.surface)
        }.clipShape(RoundedRectangle(cornerRadius: 24))
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .onChange(of: items) { _, _ in index = min(index, max(0, items.count - 1)) }
            .task(id: rotate) {
                guard rotate else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(6)) } catch { return }
                    if !Task.isCancelled { move(1) }
                }
            }
    }
    private func move(_ direction: Int) {
        guard !items.isEmpty else { return }
        if reduceMotion { index = (index + direction + items.count) % items.count }
        else { withAnimation(.easeInOut(duration: 0.35)) { index = (index + direction + items.count) % items.count } }
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var results: [Anime] = []
    @State private var busy = false
    @State private var error: String?
    @State private var refresh = UUID()
    var body: some View {
        List {
            if !store.state.preferences.animexEnabled { Text("Enable Animex in Sources to search its catalog.") }
            else if busy { ProgressView("Searching Animex…") }
            else if let error { ProblemView(message: error) { refresh = UUID() } }
            else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Find your next obsession", systemImage: "magnifyingglass", description: Text("Search anime from your enabled sources."))
            } else if results.isEmpty { ContentUnavailableView.search(text: query) }
            ForEach(results) { anime in NavigationLink { AnimeDetailView(anime: anime) } label: { AnimeRow(anime: anime) } }
        }
        .navigationTitle("Discover").searchable(text: $query, prompt: "Search anime")
        .toolbar { SourceToolbar() }
        .task(id: query + refresh.uuidString + String(store.state.preferences.animexEnabled)) {
            results = []; error = nil; busy = false
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, store.state.preferences.animexEnabled else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                busy = true
                let found = try await CatalogAPI.shared.search(text)
                try Task.checkCancellation()
                results = found; busy = false
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription; busy = false } }
        }
    }
}
