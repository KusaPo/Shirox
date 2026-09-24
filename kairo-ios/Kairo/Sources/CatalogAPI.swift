import Foundation

enum DiscoverySource: String, CaseIterable, Identifiable {
    case animex, anilist
    var id: String { rawValue }
    var name: String { self == .animex ? "Animex" : "AniList" }
    var browseTitle: String { self == .animex ? "Explore Animex" : "Popular on AniList" }
}

enum DiscoverOrder: String, CaseIterable, Identifiable {
    case popular = "POPULARITY_DESC", trending = "TRENDING_DESC", rated = "SCORE_DESC"
    var id: String { rawValue }
    var name: String {
        switch self { case .popular: "Popular"; case .trending: "Trending"; case .rated: "Top rated" }
    }
}

struct DiscoverPage {
    var anime: [Anime]
    var hasMore: Bool
    var note: String? = nil
}

actor CatalogAPI {
    static let shared = CatalogAPI()
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 35
        session = URLSession(configuration: config)
    }

    private func request(_ url: URL, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw KairoError.message("The source returned no HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 { throw KairoError.message("This source is limiting requests. Wait a moment before retrying.") }
            throw KairoError.message("\(url.host ?? "Source") returned HTTP \(http.statusCode). Try again later or choose another source.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw KairoError.message("The source returned an unexpected response.") }
        if json["errors"] != nil { throw KairoError.message("The catalog rejected the request. Its API may have changed.") }
        return json
    }

    func trending() async throws -> [Anime] {
        let query = """
        { Page(page:1,perPage:10) { media(type:ANIME,sort:TRENDING_DESC,isAdult:false) {
        id idMal title { english romaji } coverImage { extraLarge large } bannerImage description episodes
        nextAiringEpisode { episode } seasonYear genres } } }
        """
        let json = try await request(URL(string: "https://graphql.anilist.co")!, body: ["query": query])
        guard let data = json["data"] as? [String: Any], let page = data["Page"] as? [String: Any], let items = page["media"] as? [[String: Any]] else { throw KairoError.message("Trending data has an unexpected format.") }
        return items.compactMap(Self.anilistAnime)
    }

    func discover(_ source: DiscoverySource, page: Int, order: DiscoverOrder, genre: String) async throws -> DiscoverPage {
        switch source {
        case .animex:
            // Animex exposes search, but no verified page cursor or recommendation
            // feed. Vary search terms to browse samples and keep full-title search.
            let seeds = ["an", "no", "ka", "to", "mi", "sa", "ko", "shi", "ra", "ki", "ma", "re", "ha", "yu", "ta", "mo", "se", "na", "da", "fu", "ri", "chi", "su", "ai"]
            let index = (max(1, page) - 1) * 2
            guard index < seeds.count else { return DiscoverPage(anime: [], hasMore: false) }
            do {
                var found: [Anime] = []
                for seed in seeds[index..<min(index + 2, seeds.count)] {
                    found += try await search(seed)
                }
                let filtered = genre == "All" ? found : found.filter { $0.genres.contains(genre) }
                let unique = Array(Dictionary(grouping: filtered, by: \.id).values.compactMap(\.first))
                let sorted: [Anime]
                switch order {
                case .popular: sorted = unique.sorted { $0.title < $1.title }
                case .trending: sorted = unique.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
                case .rated: sorted = unique.sorted { $0.title < $1.title }
                }
                return DiscoverPage(anime: sorted, hasMore: index + 2 < seeds.count,
                                    note: "Animex provides title search, not a complete paginated browse feed. These are catalog samples; search to find a specific show.")
            } catch {
                var fallback = try await discover(.anilist, page: page, order: order, genre: genre)
                fallback.note = "Animex catalog browse is unavailable. Showing AniList titles; Kairo checks Animex for episodes when you open one."
                return fallback
            }
        case .anilist:
            let query = """
            query Browse($page:Int,$sort:[MediaSort],$genre:String) {
              Page(page:$page,perPage:30) { pageInfo { hasNextPage } media(type:ANIME,sort:$sort,genre:$genre,isAdult:false) {
              id idMal title { english romaji } coverImage { extraLarge large } bannerImage description episodes
              nextAiringEpisode { episode } seasonYear genres
            } } }
            """
            let json = try await request(URL(string: "https://graphql.anilist.co")!, body: ["query": query,
                "variables": ["page": max(1, page), "sort": [order.rawValue], "genre": genre == "All" ? NSNull() as Any : genre as Any]])
            guard let data = json["data"] as? [String: Any], let page = data["Page"] as? [String: Any],
                  let items = page["media"] as? [[String: Any]] else { throw KairoError.message("AniList browse data is unavailable.") }
            let info = page["pageInfo"] as? [String: Any]
            return DiscoverPage(anime: items.compactMap(Self.anilistAnime), hasMore: info?["hasNextPage"] as? Bool ?? false)
        }
    }

    func search(_ keyword: String, source: DiscoverySource) async throws -> [Anime] {
        if source == .animex { return try await search(keyword) }
        let query = """
        query Search($text:String) { Page(page:1,perPage:24) { media(type:ANIME,search:$text,isAdult:false) {
          id idMal title { english romaji } coverImage { extraLarge large } bannerImage description episodes
          nextAiringEpisode { episode } seasonYear genres
        } } }
        """
        let json = try await request(URL(string: "https://graphql.anilist.co")!, body: ["query": query, "variables": ["text": keyword]])
        guard let data = json["data"] as? [String: Any], let page = data["Page"] as? [String: Any],
              let items = page["media"] as? [[String: Any]] else { throw KairoError.message("AniList search data is unavailable.") }
        return items.compactMap(Self.anilistAnime)
    }

    func search(_ keyword: String) async throws -> [Anime] {
        let query = """
        query FastSearch($query:String,$limit:Int) { catalogAnime(filter:{query:$query},limit:$limit) {
        items { id anilistId malId titleRomaji titleEnglish coverImage bannerImage episodeCount seasonYear genres } } }
        """
        let json = try await request(URL(string: "https://graphql.animex.one/graphql")!, body: ["query": query, "variables": ["query": keyword, "limit": 24]])
        guard let data = json["data"] as? [String: Any], let catalog = data["catalogAnime"] as? [String: Any], let items = catalog["items"] as? [[String: Any]] else { throw KairoError.message("Animex's catalog response changed. Search could not be read.") }
        return items.compactMap(Self.animexAnime)
    }

    func resolve(_ anime: Anime) async throws -> Anime {
        if anime.moduleID != nil { return try await ModuleCatalog.shared.resolve(anime) }
        if let slug = anime.sourceID, !slug.isEmpty { return anime }
        let candidates = try await search(anime.title)
        var match = candidates.first { $0.anilistID != nil && $0.anilistID == anime.anilistID }
        if match == nil, let alternate = anime.alternateTitle, alternate != anime.title {
            let alternateCandidates = try await search(alternate)
            match = alternateCandidates.first { $0.anilistID != nil && $0.anilistID == anime.anilistID }
        }
        guard var result = match else { throw KairoError.message("This title could not be matched to Animex by its AniList ID. Search the source in Discover; no guessed episode will be played.") }
        result.malID = result.malID ?? anime.malID
        result.synopsis = anime.synopsis
        result.banner = result.banner ?? anime.banner
        return result
    }

    func streams(_ anime: Anime, episode: Int, audio: AudioChoice) async throws -> [StreamOption] {
        if anime.moduleID != nil { return try await ModuleCatalog.shared.streams(anime, episode: episode, audio: audio) }
        return try await withThrowingTaskGroup(of: [StreamOption].self) { group in
            group.addTask { try await self.loadStreams(anime, episode: episode, audio: audio) }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
                throw KairoError.message("The source took too long to find playable media. Retry or choose another audio option.")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }

    private func loadStreams(_ anime: Anime, episode: Int, audio: AudioChoice) async throws -> [StreamOption] {
        let resolved = try await resolve(anime)
        guard let slug = resolved.sourceID, episode > 0 else { throw KairoError.message("The episode has no source identifier.") }
        let servers = try await request(endpoint("servers", query: ["id": slug, "epNum": String(episode)]))
        let providers = servers[audio == .sub ? "subProviders" : "dubProviders"] as? [[String: Any]] ?? []
        guard !providers.isEmpty else { throw KairoError.message("No \(audio.label) providers list this episode. Try another audio option.") }
        var streams: [StreamOption] = []
        var lastFailure: Error?
        for provider in providers.prefix(4) {
            try Task.checkCancellation()
            guard let providerID = Self.identifier(provider["id"]) else { continue }
            do {
                let response = try await request(endpoint("sources", query: ["id": slug, "epNum": String(episode), "type": audio.rawValue, "providerId": providerID]))
                let headers = response["headers"] as? [String: String] ?? [:]
                let episodePreview = EpisodeImageResource.parse(response["thumbnail"], headers: response["thumbnailHeaders"] as? [String: String] ?? [:])
                    ?? EpisodeImageResource.parse(servers["thumbnail"], headers: servers["thumbnailHeaders"] as? [String: String] ?? [:])
                for (index, source) in (response["sources"] as? [[String: Any]] ?? []).enumerated() {
                    guard let text = source["url"] as? String, let url = WebAddress.media(text) else { continue }
                    let ext = url.pathExtension.lowercased()
                    guard ["m3u8", "mp4", "m4v"].contains(ext) else { continue }
                    let preview = EpisodeImageResource.parse(source["thumbnail"], headers: source["thumbnailHeaders"] as? [String: String] ?? [:]) ?? episodePreview
                    streams.append(StreamOption(id: "\(providerID)-\(index)", provider: providerID, url: url, headers: headers, audio: audio, label: "\(providerID.uppercased()) · \(audio.label)", preview: preview))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { lastFailure = error }
        }
        if streams.isEmpty { throw lastFailure ?? KairoError.message("The providers returned no supported video URLs. Embedded-player pages cannot be played directly.") }
        return streams
    }

    private func endpoint(_ name: String, query: [String: String]) -> URL {
        var parts = URLComponents(string: "https://pp.animex.one/rest/api/\(name)")!
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }

    static func identifier(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? Int { return String(number) }
        return nil
    }
    static func image(_ value: Any?) -> URL? {
        if let text = value as? String { return WebAddress.media(text) }
        if let object = value as? [String: Any] { return image(object["extraLarge"] ?? object["large"] ?? object["medium"]) }
        return nil
    }
    static func anilistAnime(_ row: [String: Any]) -> Anime? {
        guard let id = row["id"] as? Int, let names = row["title"] as? [String: Any], let title = names["english"] as? String ?? names["romaji"] as? String else { return nil }
        let next = (row["nextAiringEpisode"] as? [String: Any])?["episode"] as? Int
        return Anime(anilistID: id, malID: row["idMal"] as? Int, title: title, alternateTitle: names["romaji"] as? String, cover: image(row["coverImage"]), banner: image(row["bannerImage"]), synopsis: (row["description"] as? String ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression), episodeCount: row["episodes"] as? Int ?? next.map { max(0, $0 - 1) }, year: row["seasonYear"] as? Int, genres: row["genres"] as? [String] ?? [])
    }
    static func animexAnime(_ row: [String: Any]) -> Anime? {
        guard let slug = identifier(row["id"]), let title = row["titleEnglish"] as? String ?? row["titleRomaji"] as? String else { return nil }
        return Anime(anilistID: row["anilistId"] as? Int, malID: row["malId"] as? Int, sourceID: slug, title: title, alternateTitle: row["titleRomaji"] as? String, cover: image(row["coverImage"]), banner: image(row["bannerImage"]), episodeCount: row["episodeCount"] as? Int, year: row["seasonYear"] as? Int, genres: row["genres"] as? [String] ?? [])
    }
}
