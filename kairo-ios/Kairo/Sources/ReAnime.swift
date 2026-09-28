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

actor ReAnimeAPI {
    static let shared = ReAnimeAPI()
    static let moduleID = "builtin:reanime"
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
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
    final class Coordinator: NSObject, WKNavigationDelegate {
        var owner: ReAnimeWebView
        init(_ owner: ReAnimeWebView) { self.owner = owner }
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
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.contentInsetAdjustmentBehavior = .automatic
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { context.coordinator.owner = self }
}
