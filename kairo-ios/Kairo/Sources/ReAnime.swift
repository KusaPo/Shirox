import Foundation
import SwiftUI
import WebKit

struct ReAnimeEpisode {
    var number: Int
    var title: String?
    var thumbnail: URL?
    var subbed: Bool
    var dubbed: Bool
    func moduleEpisode(slug: String) -> ModuleEpisode {
        ModuleEpisode(number: number, href: "https://reanime.to/watch/\(slug)?ep=\(number)",
                      title: title, thumbnail: thumbnail, headers: [:])
    }
}

struct ReAnimeServer: Identifiable {
    let id: String
    let name: String
    let url: URL
    let audio: AudioChoice
}

actor ReAnimeAPI {
    static let shared = ReAnimeAPI()
    static let moduleID = "builtin:reanime"
    private let session: URLSession
    init(configuration provided: URLSessionConfiguration? = nil) {
        let configuration = provided ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 35
        session = URLSession(configuration: configuration)
    }
    static func slug(_ anime: Anime) -> String? {
        guard anime.moduleID == moduleID, let value = anime.sourceID, !value.isEmpty,
              value.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_").inverted) == nil else { return nil }
        return value
    }
    static func watchURL(_ anime: Anime, episode: Int, audio: AudioChoice) -> URL? {
        guard let slug = slug(anime), episode > 0 else { return nil }
        var parts = URLComponents(string: "https://reanime.to/watch/\(slug)")!
        parts.queryItems = [URLQueryItem(name: "ep", value: String(episode)), URLQueryItem(name: "lang", value: audio.rawValue)]
        return parts.url
    }
    static func episodeLink(_ url: URL) -> (Anime, Int, AudioChoice)? {
        guard url.scheme == "https", url.host == "reanime.to",
              url.pathComponents.count == 3, url.pathComponents[1] == "watch" else { return nil }
        let slug = url.lastPathComponent
        var anime = Anime(sourceID: slug, title: slug.replacingOccurrences(of: "-", with: " "))
        anime.moduleID = moduleID
        anime.moduleName = "ReAnime"
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let episode = Int(query.first { $0.name == "ep" }?.value ?? "1") ?? 1
        guard episode > 0, episode <= 5000, Self.slug(anime) != nil else { return nil }
        return (anime, episode, query.first { $0.name == "lang" }?.value == "dub" ? .dub : .sub)
    }
    static func downloadPage(_ anime: Anime, episode: Int) -> URL? {
        guard slug(anime) != nil, episode > 0 else { return nil }
        var parts = URLComponents(string: "https://reanime.to/download")!
        parts.queryItems = [URLQueryItem(name: "q", value: "\(anime.title) e\(String(format: "%02d", episode))")]
        return parts.url
    }
    private func json(_ path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var parts = URLComponents(string: "https://reanime.to\(path)")!
        parts.queryItems = query
        guard let url = parts.url else { throw KairoError.message("ReAnime URL is invalid.") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw KairoError.message("ReAnime is unavailable (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Retry or use another source.")
        }
        guard data.count <= 5_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KairoError.message("ReAnime returned an unexpected catalog response.")
        }
        return object
    }
    private static func artwork(_ row: [String: Any]) -> URL? {
        CatalogAPI.image(row["cover_image"])
    }
    private static func title(_ row: [String: Any]) -> String? {
        let names = row["title"] as? [String: Any] ?? [:]
        return [names["english"], names["romaji"], names["native"]]
            .compactMap { $0 as? String }.first { !$0.isEmpty }
    }
    private static func anime(_ row: [String: Any]) -> Anime? {
        guard let slug = row["anime_id"] as? String,
              slug.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_").inverted) == nil,
              let title = title(row), row["is_adult"] as? Bool != true else { return nil }
        let names = row["title"] as? [String: Any] ?? [:]
        var result = Anime(anilistID: (row["anilist_id"] as? Int).flatMap { $0 > 0 ? $0 : nil },
                           malID: row["mal_id"] as? Int, sourceID: slug, title: title,
                           alternateTitle: names["romaji"] as? String,
                           cover: artwork(row), banner: CatalogAPI.image(row["banner_image"]),
                           synopsis: (row["description"] as? String ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
                           episodeCount: row["episodes_total"] as? Int ?? row["episodes"] as? Int,
                           year: row["season_year"] as? Int, genres: row["genres"] as? [String] ?? [])
        result.moduleID = moduleID
        result.moduleName = "ReAnime"
        return result
    }
    func search(_ keyword: String) async throws -> [Anime] {
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let result = try await json("/api/v1/search", query: [.init(name: "q", value: term), .init(name: "limit", value: "30")])
        guard let rows = result["results"] as? [[String: Any]] else { throw KairoError.message("ReAnime search format changed.") }
        return rows.compactMap(Self.anime)
    }
    func episodes(_ anime: Anime) async throws -> [ReAnimeEpisode] {
        guard let slug = Self.slug(anime) else { throw KairoError.message("Invalid ReAnime title identifier.") }
        let result = try await json("/api/v1/anime/\(slug)/episodes", query: [.init(name: "limit", value: "2000")])
        guard let rows = result["data"] as? [[String: Any]] else { throw KairoError.message("ReAnime episode format changed.") }
        if (result["totalPages"] as? Int ?? 1) > 1 { throw KairoError.message("ReAnime returned a partial episode list. Update the source before playing it.") }
        var seen = Set<Int>()
        let episodes = rows.compactMap { row -> ReAnimeEpisode? in
            guard let number = row["episode_number"] as? Int, number > 0,
                  row["playable"] as? Bool != false, seen.insert(number).inserted else { return nil }
            let raw = row["title"] as? String
            let title = raw?.isEmpty == false && raw != "Episode \(number)" ? raw : nil
            return ReAnimeEpisode(number: number, title: title,
                                  thumbnail: CatalogAPI.image(row["thumbnail"]),
                                  subbed: row["subbed"] as? Bool ?? false,
                                  dubbed: row["dubbed"] as? Bool ?? false)
        }.sorted { $0.number < $1.number }
        guard !episodes.isEmpty else { throw KairoError.message("ReAnime lists no playable episodes for this title.") }
        return episodes
    }
    func resolve(_ anime: Anime) async throws -> Anime {
        guard let slug = Self.slug(anime) else { throw KairoError.message("Invalid ReAnime title identifier.") }
        async let details = json("/api/v1/anime/\(slug)")
        async let episodeList = episodes(anime)
        let (data, list) = try await (details, episodeList)
        var result = Self.anime(data) ?? anime
        result.moduleEpisodes = list.map { $0.moduleEpisode(slug: slug) }
        result.episodeCount = list.last?.number
        return result
    }

    func servers(_ anime: Anime, episode: Int) async throws -> [ReAnimeServer] {
        guard Self.slug(anime) != nil, episode > 0 else { throw KairoError.message("Invalid ReAnime episode.") }
        let id: Int
        if let known = anime.anilistID, known > 0 { id = known }
        else {
            guard let slug = Self.slug(anime),
                  let found = try await json("/api/v1/anime/\(slug)")["anilist_id"] as? Int,
                  found > 0 else { throw KairoError.message("ReAnime did not provide a player identifier for this title.") }
            id = found
        }
        let response = try await json("/api/flix/\(id)/\(episode)")
        guard response["success"] as? Bool == true,
              let rows = response["servers"] as? [[String: Any]] else {
            throw KairoError.message("ReAnime returned no player servers for this episode.")
        }
        return rows.compactMap { row in
            guard let raw = row["dataLink"] as? String,
                  let url = URL(string: raw), url.scheme == "https", url.host == "flixcloud.cc",
                  url.path.hasPrefix("/e/"),
                  let type = row["dataType"] as? String,
                  let audio = type.contains("dub") ? AudioChoice.dub : (type.contains("sub") ? .sub : nil) else { return nil }
            let name = row["serverName"] as? String ?? "Player"
            return ReAnimeServer(id: row["$id"] as? String ?? "\(audio.rawValue)-\(name)", name: name, url: url, audio: audio)
        }
    }
    func streams(_ anime: Anime, episode: Int, audio: AudioChoice) async throws -> [StreamOption] {
        let listed = try await servers(anime, episode: episode).filter { $0.audio == audio }
        guard !listed.isEmpty else { throw KairoError.message("ReAnime lists no \(audio.label) player for episode \(episode). Try the other language.") }
        return listed.map { server in
            StreamOption(id: server.id, provider: server.id, url: server.url, headers: [:], audio: audio,
                         label: "ReAnime · \(server.name) · \(audio.shortLabel)")
        }
    }
}

struct ReAnimePlayback: Identifiable {
    let id = UUID()
    let anime: Anime
    let episode: Int
    let audio: AudioChoice
    var preferredServerID: String? = nil
}

struct ReAnimePlayer: View {
    let request: ReAnimePlayback
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @AppStorage("playerAutoPlayNext") private var autoPlayNext = false
    @State private var episode: Int
    @State private var audio: AudioChoice
    @State private var servers: [ReAnimeServer] = []
    @State private var selected: ReAnimeServer?
    @State private var error: String?
    @State private var loading = true
    @State private var playerLoading = true
    @State private var playerError: String?
    @State private var watchedSeconds = 0.0
    @State private var watchedDuration = 0.0
    init(request: ReAnimePlayback) {
        self.request = request
        _episode = State(initialValue: request.episode)
        _audio = State(initialValue: request.audio)
    }
    private var available: [ReAnimeServer] { servers.filter { $0.audio == audio } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                Text("\(request.anime.title) · Episode \(episode)").lineLimit(1).font(.subheadline.bold())
                Spacer()
            }.padding(.horizontal, 8)
            ZStack {
                Color.black
                if let selected {
                    ReAnimeWebView(url: selected.url, loading: $playerLoading, problem: $playerError,
                                   referer: ReAnimeAPI.watchURL(request.anime, episode: episode, audio: audio),
                                   resumeAt: watchedSeconds > 5 ? watchedSeconds : (store.progress(request.anime, episode: episode).flatMap { $0.finished ? nil : $0.seconds } ?? 0),
                                   onProgress: { seconds, duration, ended in
                                       watchedSeconds = seconds; watchedDuration = duration
                                       store.record(request.anime, episode: episode, seconds: seconds, duration: duration, finished: ended)
                                       if ended && autoPlayNext && episode < (request.anime.episodeCount ?? episode) { episode += 1 }
                                   })
                        .id(selected.id).ignoresSafeArea(edges: .bottom)
                    if playerLoading { ProgressView("Loading player…").tint(.white) }
                } else if loading { ProgressView("Finding episode player…").tint(.white) }
                else { ContentUnavailableView("No player", systemImage: "play.slash", description: Text(error ?? "No \(audio.shortLabel) server is available.")) }
            }
            if let playerError { Text(playerError).font(.caption).foregroundStyle(.orange).padding(8) }
            if watchedDuration > 0 {
                ProgressView(value: min(watchedSeconds, watchedDuration), total: watchedDuration)
                    .tint(Theme.purple).padding(.horizontal, 12)
            }
            HStack {
                Picker("Language", selection: $audio) {
                    ForEach(AudioChoice.allCases) { choice in
                        if servers.contains(where: { $0.audio == choice }) { Text(choice.shortLabel).tag(choice) }
                    }
                }.pickerStyle(.segmented).frame(maxWidth: 160)
                Picker("Server", selection: Binding(get: { selected?.id ?? "" }, set: { id in selected = available.first { $0.id == id } })) {
                    ForEach(available) { server in Text(server.name).tag(server.id) }
                }.frame(maxWidth: 130)
                Spacer()
                Button { episode -= 1 } label: { Image(systemName: "backward.end.fill") }
                    .disabled(episode <= 1)
                Button { episode += 1 } label: { Image(systemName: "forward.end.fill") }
                    .disabled(episode >= (request.anime.episodeCount ?? episode))
            }.padding(12)
            if let url = ReAnimeAPI.watchURL(request.anime, episode: episode, audio: audio) {
                Link("Open original player if this server fails", destination: url)
                    .font(.caption).padding(.bottom, 12)
            }
        }
        .foregroundStyle(.white).background(.black).tint(Theme.purple)
        .task(id: episode) {
            loading = true; selected = nil; error = nil; servers = []
            watchedSeconds = 0; watchedDuration = 0
            do {
                let result = try await ReAnimeAPI.shared.servers(request.anime, episode: episode)
                try Task.checkCancellation()
                servers = result
                if !result.contains(where: { $0.audio == audio }), let first = result.first { audio = first.audio }
                selected = result.first { $0.id == request.preferredServerID && $0.audio == audio }
                    ?? result.first { $0.audio == audio }
                if selected == nil { error = "ReAnime returned no playable server." }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            loading = false
        }
        .onChange(of: audio) { _, choice in selected = servers.first { $0.audio == choice }; playerError = nil; playerLoading = true }
    }
}

struct ReAnimePage: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

struct ReAnimeBrowser: View {
    let page: ReAnimePage
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var problem: String?
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            ReAnimeWebView(url: page.url, loading: $loading, problem: $problem).ignoresSafeArea(edges: .bottom)
            if loading { ProgressView("Opening ReAnime…").tint(.white).padding(12)
                .background(.black.opacity(0.8), in: Capsule()).padding(.top, 62) }
            if let problem {
                VStack(spacing: 10) {
                    Text(problem).multilineTextAlignment(.center)
                    Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
                }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(.top, 95)
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                Spacer()
                Text(page.title).font(.caption.weight(.semibold)).lineLimit(1)
            }.padding(12).background(.ultraThinMaterial)
        }
    }
}

struct ReAnimeWebView: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    @Binding var problem: String?
    var referer: URL? = nil
    var resumeAt: Double = 0
    var onProgress: ((Double, Double, Bool) -> Void)? = nil
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var owner: ReAnimeWebView
        init(_ owner: ReAnimeWebView) { self.owner = owner }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "kairoPlayback", let value = message.body as? [String: Any],
                  let seconds = (value["seconds"] as? NSNumber)?.doubleValue,
                  let duration = (value["duration"] as? NSNumber)?.doubleValue,
                  seconds.isFinite, duration.isFinite, duration > 0 else { return }
            let ended = value["ended"] as? Bool ?? false
            DispatchQueue.main.async { self.owner.onProgress?(seconds, duration, ended) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { owner.loading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            owner.loading = false; owner.problem = error.localizedDescription
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            owner.loading = false; owner.problem = error.localizedDescription
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        if onProgress != nil {
            configuration.userContentController.add(context.coordinator, name: "kairoPlayback")
            let start = resumeAt.isFinite && resumeAt > 5 && resumeAt < 360_000 ? resumeAt : 0
            let script = """
            (() => {
              let last = -1;
              let resumed = false;
              const resumeAt = \(start);
              setInterval(() => {
                const video = document.querySelector('video');
                if (!video || !Number.isFinite(video.duration) || video.duration <= 0) return;
                if (!resumed) {
                  resumed = true;
                  if (resumeAt > 5 && resumeAt < video.duration - 10) video.currentTime = resumeAt;
                }
                const seconds = video.currentTime;
                if (!Number.isFinite(seconds) || (Math.abs(seconds - last) < 2 && !video.ended)) return;
                last = seconds;
                window.webkit.messageHandlers.kairoPlayback.postMessage({seconds, duration: video.duration, ended: video.ended});
              }, 3000);
            })();
            """
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.contentInsetAdjustmentBehavior = .automatic
        var request = URLRequest(url: url)
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        view.load(request)
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { context.coordinator.owner = self }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "kairoPlayback")
        uiView.stopLoading()
    }
}
