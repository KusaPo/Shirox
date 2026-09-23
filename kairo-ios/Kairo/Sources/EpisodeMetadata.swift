import Foundation

struct EpisodeMetadata: Equatable {
    var number: Int
    var title: String?
    var thumbnail: URL?

    // Never assign by array position: providers can omit episodes or list them backwards.
    static func streamingEpisode(_ row: [String: Any]) -> EpisodeMetadata? {
        guard let text = row["title"] as? String,
              let pattern = try? NSRegularExpression(pattern: #"^\s*Episode\s+([0-9]+)(?:\s+[-–—:]\s*(.+))?\s*$"#, options: [.caseInsensitive]),
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let number = Int(text[numberRange]), number > 0 else { return nil }
        let titleRange = Range(match.range(at: 2), in: text)
        let title = titleRange.map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        return EpisodeMetadata(number: number, title: title?.isEmpty == false ? title : nil,
                               thumbnail: (row["thumbnail"] as? String).flatMap(WebAddress.media))
    }

    static func jikanEpisode(_ row: [String: Any]) -> EpisodeMetadata? {
        guard let value = row["mal_id"] as? NSNumber else { return nil }
        let raw = value.doubleValue
        guard raw.isFinite, raw > 0, raw <= 5000, raw.rounded() == raw else { return nil }
        let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EpisodeMetadata(number: Int(raw), title: title?.isEmpty == false ? title : nil)
    }

    static func merge(_ items: [EpisodeMetadata]) -> [Int: EpisodeMetadata] {
        var result: [Int: EpisodeMetadata] = [:]
        for item in items {
            if var existing = result[item.number] {
                existing.title = existing.title ?? item.title
                existing.thumbnail = existing.thumbnail ?? item.thumbnail
                result[item.number] = existing
            } else { result[item.number] = item }
        }
        return result
    }
}

struct EpisodeMetadataPage {
    var episodes: [Int: EpisodeMetadata]
    var notice: String?
}

actor EpisodeMetadataAPI {
    static let shared = EpisodeMetadataAPI()
    private let session: URLSession
    private var mediaCache: [Int: (Date, Int?, [EpisodeMetadata])] = [:]
    private var pageCache: [String: (Date, EpisodeMetadataPage)] = [:]
    private var nextJikanRequest = Date.distantPast

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        session = URLSession(configuration: config)
    }

    func episodes(for anime: Anime, page: Int) async throws -> EpisodeMetadataPage {
        let key = "\(anime.id)|\(anime.malID ?? 0)|\(page)"
        if let cached = pageCache[key], Date().timeIntervalSince(cached.0) < 3600 { return cached.1 }
        var items: [EpisodeMetadata] = []
        var malID = anime.malID
        var unavailable = false
        if let id = anime.anilistID {
            do {
                let media = try await media(id)
                malID = malID ?? media.0
                items = media.1
            } catch is CancellationError { throw CancellationError() }
            catch { unavailable = true }
        }
        if let malID, malID > 0 {
            do {
                // Reserve request times before suspending so concurrent detail pages
                // cannot burst past the metadata service's rate limit.
                let slot = max(Date(), nextJikanRequest)
                nextJikanRequest = slot.addingTimeInterval(1)
                let delay = slot.timeIntervalSinceNow
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                let json = try await request(URL(string: "https://api.jikan.moe/v4/anime/\(malID)/episodes?page=\(max(1, page))")!)
                guard let rows = json["data"] as? [[String: Any]] else { throw KairoError.message("Unexpected episode metadata.") }
                items += rows.compactMap(EpisodeMetadata.jikanEpisode)
            } catch is CancellationError { throw CancellationError() }
            catch { unavailable = true }
        }
        try Task.checkCancellation()
        let lower = (max(1, page) - 1) * 100 + 1
        let records = EpisodeMetadata.merge(items.filter { (lower..<(lower + 100)).contains($0.number) })
        let notice: String? = unavailable
            ? "Some episode details could not be loaded. You can still choose an episode."
            : nil
        let result = EpisodeMetadataPage(episodes: records, notice: notice)
        if !unavailable {
            if pageCache.count >= 100 { pageCache.removeAll() }
            pageCache[key] = (Date(), result)
        }
        return result
    }

    private func media(_ id: Int) async throws -> (Int?, [EpisodeMetadata]) {
        if let cached = mediaCache[id], Date().timeIntervalSince(cached.0) < 3600 { return (cached.1, cached.2) }
        let query = "query($id:Int){Media(id:$id,type:ANIME){idMal streamingEpisodes{title thumbnail}}}"
        let json = try await request(URL(string: "https://graphql.anilist.co")!, body: ["query": query, "variables": ["id": id]])
        guard let data = json["data"] as? [String: Any], let media = data["Media"] as? [String: Any] else { throw KairoError.message("No matching episode metadata.") }
        let episodes = (media["streamingEpisodes"] as? [[String: Any]] ?? []).compactMap(EpisodeMetadata.streamingEpisode)
        let malID = media["idMal"] as? Int
        if mediaCache.count >= 50 { mediaCache.removeAll() }
        mediaCache[id] = (Date(), malID, episodes)
        return (malID, episodes)
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
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["errors"] == nil else {
            throw KairoError.message("Episode metadata is temporarily unavailable.")
        }
        return json
    }
}
