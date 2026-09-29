import Foundation

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
    // A media gateway is required because /api/flix only returns embed pages.
    // The gateway must serve ordinary HLS playlists and segments over HTTPS.
    static func gatewayURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              (url.path.isEmpty || url.path == "/"), url.query == nil, url.fragment == nil else { return nil }
        return url
    }
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
    func home(_ order: DiscoverOrder, genre: String) async throws -> [Anime] {
        let result = try await json("/api/v1/home")
        let section: String
        switch order {
        case .popular: section = "trending"
        case .trending: section = "latest_aired"
        case .rated: section = "new_on_site"
        }
        guard let rows = result[section] as? [[String: Any]] else {
            throw KairoError.message("ReAnime's home feed changed. Search for a title instead.")
        }
        return rows.compactMap(Self.anime).filter { genre == "All" || $0.genres.contains(genre) }
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
        guard let gateway = Self.gatewayURL(UserDefaults.standard.string(forKey: "reanimeGatewayURL") ?? "") else {
            throw KairoError.message("ReAnime native playback needs a media gateway. Set its HTTPS address in Sources & preferences.")
        }
        var results: [StreamOption] = []
        var lastError: Error?
        for server in listed {
            do {
                let media = try await nativeStream(server, gateway: gateway)
                results.append(StreamOption(id: server.id, provider: server.id, url: media, headers: [:], audio: audio,
                                            label: "ReAnime · \(server.name) · \(audio.shortLabel)"))
            } catch { lastError = error }
        }
        guard !results.isEmpty else { throw lastError ?? KairoError.message("No native ReAnime stream is available.") }
        return results
    }

    private func nativeStream(_ server: ReAnimeServer, gateway: URL) async throws -> URL {
        var parts = URLComponents(url: gateway.appendingPathComponent("resolve"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "embed", value: server.url.absoluteString)]
        var request = URLRequest(url: parts.url!)
        if let access = UserDefaults.standard.string(forKey: "reanimeGatewayKey"), !access.isEmpty {
            request.setValue(access, forHTTPHeaderField: "X-Kairo-Access")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count < 16_384, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["url"] as? String, let url = URL(string: raw),
              url.scheme == "https", url.host == gateway.host, url.pathExtension.lowercased() == "m3u8" else {
            throw KairoError.message("The ReAnime gateway did not return a usable HTTPS HLS stream.")
        }
        var probe = URLRequest(url: url)
        probe.timeoutInterval = 15
        let (manifest, manifestResponse) = try await session.data(for: probe)
        try Task.checkCancellation()
        guard (manifestResponse as? HTTPURLResponse)?.statusCode == 200,
              manifest.count < 1_000_000,
              String(data: manifest.prefix(32), encoding: .utf8)?.hasPrefix("#EXTM3U") == true else {
            throw KairoError.message("The ReAnime gateway did not supply an iOS-compatible HLS playlist.")
        }
        return url
    }
}

