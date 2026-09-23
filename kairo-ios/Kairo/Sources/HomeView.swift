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
    @State private var cardWidth: CGFloat = 350
    private var rotate: Bool { !paused && !reduceMotion && !voiceOver && visible && scenePhase == .active && items.count > 1 }
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { rank, anime in
                    VStack(spacing: 0) {
                        AnimeArtwork(anime: anime).frame(height: cardWidth / 2.8)
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
            }.tabViewStyle(.page(indexDisplayMode: .never)).frame(height: cardWidth / 2.8 + 220)
                .background {
                    GeometryReader { geometry in
                        Color.clear.onAppear { cardWidth = geometry.size.width }
                            .onChange(of: geometry.size.width) { _, width in cardWidth = width }
                    }
                }
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
    @AppStorage("discoverySource") private var discoverySource = DiscoverySource.animex.rawValue
    @State private var query = ""
    @State private var items: [Anime] = []
    @State private var order: DiscoverOrder = .popular
    @State private var genre = "All"
    @State private var page = 1
    @State private var hasMore = false
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?
    @State private var generation = UUID()
    @State private var refresh = UUID()
    private let genres = ["All", "Action", "Adventure", "Comedy", "Drama", "Fantasy", "Mystery", "Romance", "Sci-Fi", "Slice of Life", "Sports"]
    private var source: DiscoverySource { DiscoverySource(rawValue: discoverySource) ?? .animex }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var displayed: [Anime] {
        guard searching else { return items }
        let matches = genre == "All" ? items : items.filter { $0.genres.contains(genre) }
        switch order {
        case .popular: return matches
        case .trending: return matches.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rated: return matches
        }
    }
    var body: some View {
        ScrollView {
            if source == .animex && !store.state.preferences.animexEnabled {
                ContentUnavailableView("Animex is disabled", systemImage: "square.stack.3d.up", description: Text("Enable it in Sources & preferences to browse or watch."))
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(searching ? "Search results" : source.browseTitle).font(.title2.bold())
                        Spacer()
                        Text("\(displayed.count) titles").font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            Menu {
                                Picker("Sort", selection: $order) {
                                    ForEach(DiscoverOrder.allCases) { option in Text(option.name).tag(option) }
                                }
                            } label: { Label(order.name, systemImage: "arrow.up.arrow.down") }
                            Menu {
                                Picker("Genre", selection: $genre) {
                                    ForEach(genres, id: \.self) { value in Text(value).tag(value) }
                                }
                            } label: { Label(genre == "All" ? "All genres" : genre, systemImage: "line.3.horizontal.decrease") }
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                    if let note, !searching { Text(note).font(.caption).foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 12)], spacing: 20) {
                        ForEach(displayed) { anime in
                            NavigationLink { AnimeDetailView(anime: anime) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Artwork(url: anime.cover).aspectRatio(2.0 / 3.0, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    Text(anime.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(anime.genres.first ?? "Anime").font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            .onAppear {
                                if anime.id == displayed.last?.id, hasMore, !busy {
                                    let current = generation
                                    Task { await loadMore(current) }
                                }
                            }
                        }
                    }
                    if busy { ProgressView("Loading more…").frame(maxWidth: .infinity).padding() }
                    if hasMore && !busy && displayed.isEmpty {
                        Button("Load more titles") { let current = generation; Task { await loadMore(current) } }
                            .frame(maxWidth: .infinity)
                    }
                    if let error { ProblemView(message: error) { if items.isEmpty { refresh = UUID() } else { let current = generation; Task { await loadMore(current) } } } }
                    if !busy && items.isEmpty && error == nil {
                        ContentUnavailableView(searching ? "No search results" : "No matching titles", systemImage: "magnifyingglass", description: Text("Try another genre or source."))
                    }
                }.padding(16)
            }
        }
        .navigationTitle("Discover").searchable(text: $query, prompt: "Search \(source.name)")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Browse source", selection: $discoverySource) {
                        ForEach(DiscoverySource.allCases) { source in Text(source.name).tag(source.rawValue) }
                    }
                } label: { HStack(spacing: 3) { Text(source.name); Image(systemName: "chevron.down").font(.caption2) }.font(.subheadline.weight(.semibold)) }
                    .accessibilityLabel("Browse source: \(source.name)")
            }
            SourceToolbar()
        }
        .refreshable { refresh = UUID() }
        .task(id: "\(query)|\(discoverySource)|\(order.rawValue)|\(genre)|\(refresh)|\(store.state.preferences.animexEnabled)") {
            generation = UUID(); let current = generation
            items = []; error = nil; note = nil; page = 1; hasMore = false; busy = false
            guard source != .animex || store.state.preferences.animexEnabled else { return }
            if searching { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await loadMore(current)
        }
    }

    private func loadMore(_ current: UUID) async {
        guard current == generation, !busy else { return }
        busy = true; error = nil
        let next = page
        do {
            if searching {
                let found = try await CatalogAPI.shared.search(query.trimmingCharacters(in: .whitespacesAndNewlines), source: source)
                guard current == generation, !Task.isCancelled else { return }
                items = found; hasMore = false
            } else {
                let result = try await CatalogAPI.shared.discover(source, page: next, order: order, genre: genre)
                guard current == generation, !Task.isCancelled else { return }
                let existing = Set(items.map(\.id))
                items += result.anime.filter { !existing.contains($0.id) }
                hasMore = result.hasMore; note = result.note; page = next + 1
            }
        } catch { if current == generation && !Task.isCancelled { self.error = error.localizedDescription } }
        if current == generation { busy = false }
    }
}
