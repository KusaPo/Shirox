import SwiftUI

struct HomeView: View {
    @Binding var selectedTab: KairoTab
    @EnvironmentObject private var store: AppStore
    @State private var busy = false
    @State private var error: String?
    @State private var detailTarget: Anime?
    @State private var detailEpisode = 1
    @State private var playback: PlaybackRequest?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !store.state.trending.isEmpty {
                    TrendingCarousel(items: store.state.trending)
                    if let error {
                        Text("Showing saved picks · \(error)")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18)
                    }
                } else if busy {
                    ZStack {
                        LinearGradient(colors: [Theme.purple.opacity(0.24), Theme.background], startPoint: .top, endPoint: .bottom)
                        ProgressView("Finding your next adventure…")
                    }.frame(height: 450)
                } else if let error {
                    ProblemView(message: error) { Task { await load() } }.padding(.top, 90)
                }
                if !store.continuing.isEmpty {
                    continueWatching
                } else if store.state.trending.isEmpty && !busy {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your next watch starts here").font(.title3.bold())
                        Text("Find a title in Discover. Your progress will appear here as you watch.").foregroundStyle(.secondary)
                        Button("Explore anime") { selectedTab = .discover }.buttonStyle(.borderedProminent)
                    }.padding(20).background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                        .padding(.horizontal, 18)
                }
                if !store.state.trending.isEmpty {
                    PosterShelf(title: "Trending now", items: store.state.trending, action: { selectedTab = .discover })
                    if !store.state.library.isEmpty {
                        PosterShelf(title: "Your collection", items: Array(store.state.library.reversed().prefix(12)), action: { selectedTab = .library })
                    }
                    if let updated = store.state.trendingUpdated {
                        Text("Trending on AniList · Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 18)
                    }
                }
            }.padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("kairo").navigationBarTitleDisplayMode(.inline)
        .toolbar { SourceToolbar() }
        .navigationDestination(item: $detailTarget) { anime in
            AnimeDetailView(anime: anime, initialEpisode: detailEpisode)
        }
        .fullScreenCover(item: $playback) { PlayerScreen(request: $0) }
        .task { if store.state.trendingUpdated.map({ Date().timeIntervalSince($0) > 3600 }) ?? true { await load() } }
        .refreshable { await load() }
        .animation(.easeOut(duration: 0.25), value: store.state.trending.count)
    }
    private var continueWatching: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Continue watching").font(.title2.bold())
                Spacer()
                Text("\(store.continuing.count)").font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.purple)
            }.padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(store.continuing) { progress in
                        Button { resume(progress) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                EpisodeThumbnail(resource: nil, anime: progress.anime, episode: progress.episode,
                                    localURL: store.readyDownload(progress.anime, episode: progress.episode, audio: store.state.preferences.audio)?.localURL)
                                    .frame(width: 230, height: 130).clipped()
                                    .overlay(alignment: .bottom) {
                                        ProgressView(value: progress.fraction).tint(Theme.purple)
                                    }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(progress.anime.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text("Episode \(progress.episode) · \(progress.remainingLabel)")
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }.padding(12)
                            }
                            .frame(width: 230, alignment: .leading)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 15))
                            .clipShape(RoundedRectangle(cornerRadius: 15))
                        }.buttonStyle(.plain)
                            .accessibilityLabel("Continue \(progress.anime.title), episode \(progress.episode)")
                            .contextMenu {
                                Button("Open title", systemImage: "list.bullet.rectangle") {
                                    detailEpisode = progress.episode
                                    detailTarget = progress.anime
                                }
                            }
                    }
                }.padding(.horizontal, 18)
            }
        }
    }
    private func resume(_ progress: WatchProgress) {
        if let saved = store.readyDownload(progress.anime, episode: progress.episode, audio: store.state.preferences.audio) {
            playback = PlaybackRequest(anime: progress.anime, episode: progress.episode,
                localURL: saved.localURL, localAudio: saved.audio)
        } else {
            detailEpisode = progress.episode
            detailTarget = progress.anime
        }
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

struct PosterShelf: View {
    let title: String
    let items: [Anime]
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                Button("See all", systemImage: "chevron.right", action: action)
                    .font(.caption.weight(.semibold)).labelStyle(.titleAndIcon)
            }.padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { anime in
                        NavigationLink { AnimeDetailView(anime: anime) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                PosterArtwork(url: anime.cover).frame(width: 135, height: 194)
                                    .clipShape(RoundedRectangle(cornerRadius: 13))
                                Text(anime.title).font(.caption.weight(.semibold)).lineLimit(2)
                                    .frame(width: 135, height: 34, alignment: .topLeading)
                            }
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 18)
            }
        }
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
        VStack(spacing: 8) {
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { rank, anime in
                    ZStack(alignment: .bottom) {
                        AnimeArtwork(anime: anime).frame(maxWidth: .infinity).frame(height: 460)
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0.14),
                            .init(color: .black.opacity(0.55), location: 0.52),
                            .init(color: .black.opacity(0.92), location: 1)
                        ], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                        VStack(spacing: 13) {
                            Text("NEXT ADVENTURE · \(rank + 1) / \(items.count)")
                                .font(.caption2.weight(.heavy)).tracking(1.7)
                                .foregroundStyle(.white.opacity(0.85))
                            Text(anime.title).font(.system(size: 30, weight: .bold, design: .rounded))
                                .lineLimit(3).minimumScaleFactor(0.75).multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                            HStack(spacing: 6) {
                                ForEach(anime.genres.prefix(3), id: \.self) { genre in
                                    Text(genre).font(.caption2.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 5)
                                        .background(.white.opacity(0.16), in: Capsule())
                                }
                            }.foregroundStyle(.white)
                            HStack(spacing: 10) {
                                NavigationLink { AnimeDetailView(anime: anime) } label: {
                                    Label("Watch", systemImage: "play.fill")
                                        .font(.subheadline.bold()).frame(maxWidth: .infinity).frame(height: 44)
                                }.buttonStyle(.borderedProminent)
                                Button { store.toggleSaved(anime) } label: {
                                    Image(systemName: store.state.library.contains(where: { $0.id == anime.id }) ? "checkmark" : "plus")
                                        .font(.headline).frame(width: 44, height: 44)
                                }.buttonStyle(.bordered).tint(.white)
                                    .accessibilityLabel("Toggle saved title")
                            }.frame(maxWidth: 300)
                        }.padding(.horizontal, 24).padding(.bottom, 28)
                    }.frame(height: 460).tag(rank)
                }
            }.tabViewStyle(.page(indexDisplayMode: .never)).frame(height: 460)
            HStack(spacing: 5) {
                ForEach(items.indices, id: \.self) { number in
                    Capsule().fill(number == index ? Theme.purple : Color.secondary.opacity(0.32))
                        .frame(width: number == index ? 16 : 5, height: 5)
                }
                Spacer()
                Button { paused.toggle() } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }
                    .accessibilityLabel(paused ? "Resume automatic slides" : "Pause automatic slides")
                    .disabled(reduceMotion || voiceOver)
            }.padding(.horizontal, 18)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: items) { _, _ in index = min(index, max(0, items.count - 1)) }
        .task(id: rotate) {
            guard rotate else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.35)) { index = (index + 1) % items.count } }
            }
        }
    }
}

struct DiscoverView: View {
    @ObservedObject private var registry = ModuleRegistry.shared
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
    private var moduleSelected: Bool { discoverySource.hasPrefix("module:") }
    private var sourceName: String { registry.modules.first(where: { $0.id == discoverySource })?.name ?? (moduleSelected ? "Removed source" : source.name) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var displayed: [Anime] {
        guard searching && !moduleSelected else { return items }
        let matches = genre == "All" ? items : items.filter { $0.genres.contains(genre) }
        switch order {
        case .popular: return matches
        case .trending: return matches.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rated: return matches
        }
    }
    var body: some View {
        ScrollView {
            if !moduleSelected && source == .animex && !store.state.preferences.animexEnabled {
                ContentUnavailableView("Animex is disabled", systemImage: "square.stack.3d.up", description: Text("Enable it in Sources & preferences to browse or watch."))
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(searching ? "Search results" : (moduleSelected ? "Explore \(sourceName)" : source.browseTitle)).font(.title2.bold())
                        Spacer()
                        Text("\(displayed.count) titles").font(.caption).foregroundStyle(.secondary)
                    }
                    if !moduleSelected { ScrollView(.horizontal, showsIndicators: false) {
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
                    }
                    if let note, !searching { Text(note).font(.caption).foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 20) {
                        ForEach(displayed) { anime in
                            NavigationLink { AnimeDetailView(anime: anime) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    PosterArtwork(url: anime.cover).aspectRatio(2.0 / 3.0, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 13))
                                        .overlay(alignment: .bottomLeading) {
                                            if let year = anime.year {
                                                Text(String(year)).font(.caption2.bold()).foregroundStyle(.white)
                                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                                    .background(.black.opacity(0.7), in: Capsule())
                                                    .padding(8)
                                            }
                                        }
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
                    if busy {
                        if items.isEmpty {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 20) {
                                ForEach(0..<6, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 13).fill(Theme.surface)
                                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        ProgressView("Loading more…").frame(maxWidth: .infinity).padding()
                    }
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
        .navigationTitle("Discover").searchable(text: $query, prompt: "Search \(sourceName)")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Browse source", selection: $discoverySource) {
                        ForEach(DiscoverySource.allCases) { source in Text(source.name).tag(source.rawValue) }
                        ForEach(registry.modules) { source in Text(source.name).tag(source.id) }
                    }
                } label: { HStack(spacing: 3) { Text(sourceName); Image(systemName: "chevron.down").font(.caption2) }.font(.subheadline.weight(.semibold)) }
                    .accessibilityLabel("Browse source: \(sourceName)")
            }
            SourceToolbar()
        }
        .refreshable { refresh = UUID() }
        .task(id: "\(query)|\(discoverySource)|\(order.rawValue)|\(genre)|\(refresh)|\(store.state.preferences.animexEnabled)") {
            generation = UUID(); let current = generation
            items = []; error = nil; note = nil; page = 1; hasMore = false; busy = false
            guard moduleSelected || source != .animex || store.state.preferences.animexEnabled else { return }
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
            if moduleSelected {
                let found = try await ModuleCatalog.shared.search(query.trimmingCharacters(in: .whitespacesAndNewlines), sourceID: discoverySource)
                guard current == generation, !Task.isCancelled else { return }
                items = found; hasMore = false
                note = found.isEmpty ? "This module has no browse feed. Search for an anime above." : "Titles returned by this source. This module format supports search but does not provide paginated recommendations."
            } else if searching {
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
