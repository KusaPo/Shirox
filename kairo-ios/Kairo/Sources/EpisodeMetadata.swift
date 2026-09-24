import Foundation
import CryptoKit
import UIKit
import ImageIO

struct EpisodeImageResource: Equatable, Hashable {
    let url: URL
    let headers: [String: String]

    init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        var sanitized: [String: String] = [:]
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            let name = key.lowercased()
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }),
                  !["host", "content-length", "connection"].contains(name),
                  !value.contains("\r"), !value.contains("\n") else { continue }
            sanitized[name] = value
        }
        self.headers = sanitized
    }

    static func parse(_ value: Any?, headers: [String: String] = [:]) -> EpisodeImageResource? {
        if let text = value as? String, let url = WebAddress.media(text) {
            return EpisodeImageResource(url: url, headers: headers)
        }
        guard let object = value as? [String: Any], let text = object["url"] as? String,
              let url = WebAddress.media(text) else { return nil }
        var merged = EpisodeImageResource(url: url, headers: headers).headers
        let explicit = EpisodeImageResource(url: url, headers: object["headers"] as? [String: String] ?? [:]).headers
        merged.merge(explicit) { _, new in new }
        return EpisodeImageResource(url: url, headers: merged)
    }

    var request: URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if request.value(forHTTPHeaderField: "Accept") == nil { request.setValue("image/*", forHTTPHeaderField: "Accept") }
        return request
    }
    var cacheKey: String {
        let values = [url.absoluteString] + headers.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
        let bytes = (try? JSONSerialization.data(withJSONObject: values)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

// Headers belong to the requested image, never to the global network session.
// Redirects may retain image presentation headers, but never forward credentials
// to a different origin or downgrade to an insecure URL.
final class EpisodeImageRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest else { completionHandler(nil); return }
        completionHandler(Self.redirect(request, from: original))
    }
    static func redirect(_ request: URLRequest, from original: URLRequest) -> URLRequest? {
        guard let target = request.url, target.scheme?.lowercased() == "https", target.user == nil, target.password == nil else { return nil }
        let sameOrigin = target.host?.lowercased() == original.url?.host?.lowercased()
            && (target.port ?? 443) == (original.url?.port ?? 443)
        var clean = request
        clean.allHTTPHeaderFields = [:]
        for (name, value) in original.allHTTPHeaderFields ?? [:] {
            if sameOrigin || ["referer", "user-agent", "accept", "accept-language", "origin"].contains(name.lowercased()) {
                clean.setValue(value, forHTTPHeaderField: name)
            }
        }
        return clean
    }
}

actor EpisodeImageLoader {
    static let shared = EpisodeImageLoader()
    private let session: URLSession
    private let cache = NSCache<NSString, UIImage>()

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: EpisodeImageRedirects(), delegateQueue: nil)
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 120
    }

    func image(_ resource: EpisodeImageResource) async throws -> UIImage {
        let key = resource.cacheKey as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let (data, response) = try await session.data(for: resource.request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty, data.count <= 10 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640
              ] as CFDictionary) else { throw KairoError.message("Episode preview is unavailable.") }
        let image = UIImage(cgImage: frame)
        cache.setObject(image, forKey: key, cost: frame.bytesPerRow * frame.height)
        return image
    }
}

struct EpisodeMetadata: Equatable {
    var number: Int
    var title: String?
    var thumbnail: URL?
    var thumbnailHeaders: [String: String] = [:]
    var imageResource: EpisodeImageResource? {
        thumbnail.map { EpisodeImageResource(url: $0, headers: thumbnailHeaders) }
    }

    // Never assign by array position: providers can omit episodes or list them backwards.
    static func streamingEpisode(_ row: [String: Any]) -> EpisodeMetadata? {
        guard let text = row["title"] as? String,
              let pattern = try? NSRegularExpression(pattern: #"^\s*Episode\s+([0-9]+)(?:\s+[-–—:]\s*(.+))?\s*$"#, options: [.caseInsensitive]),
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let number = Int(text[numberRange]), number > 0 else { return nil }
        let titleRange = Range(match.range(at: 2), in: text)
        let title = titleRange.map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        let image = EpisodeImageResource.parse(row["thumbnail"], headers: row["thumbnailHeaders"] as? [String: String] ?? [:])
        return EpisodeMetadata(number: number, title: title?.isEmpty == false ? title : nil,
                               thumbnail: image?.url, thumbnailHeaders: image?.headers ?? [:])
    }

    static func jikanEpisode(_ row: [String: Any]) -> EpisodeMetadata? {
        guard let value = row["mal_id"] as? NSNumber else { return nil }
        let raw = value.doubleValue
        guard raw.isFinite, raw > 0, raw <= 5000, raw.rounded() == raw else { return nil }
        let title = ((row["title_english"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                     ?? row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EpisodeMetadata(number: Int(raw), title: title?.isEmpty == false ? title : nil)
    }

    static func merge(_ items: [EpisodeMetadata]) -> [Int: EpisodeMetadata] {
        var result: [Int: EpisodeMetadata] = [:]
        for item in items {
            if var existing = result[item.number] {
                existing.title = existing.title ?? item.title
                if existing.thumbnail == nil { existing.thumbnail = item.thumbnail; existing.thumbnailHeaders = item.thumbnailHeaders }
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
        } else if malID == nil {
            // Source catalogues sometimes omit both external IDs. Only accept an
            // exact matching AniList title to avoid using another show's episodes.
            do {
                let media = try await matchingMedia(anime)
                malID = media.0
                items = media.1
            } catch is CancellationError { throw CancellationError() }
            catch { unavailable = true }
        }
        if malID == nil && anime.anilistID != nil {
            do {
                let match = try await matchingMedia(anime)
                malID = match.0
                items += match.1
            } catch is CancellationError { throw CancellationError() }
            catch { unavailable = true }
        }
        if let malID, malID > 0 {
            do {
                // Jikan serves 100-episode screen ranges in smaller API pages.
                // Stop at its last page rather than requesting empty pages.
                for jikanPage in ((max(1, page) - 1) * 4 + 1)...(max(1, page) * 4) {
                // Reserve request times before suspending so concurrent detail pages
                // cannot burst past the metadata service's rate limit.
                let slot = max(Date(), nextJikanRequest)
                nextJikanRequest = slot.addingTimeInterval(1)
                let delay = slot.timeIntervalSinceNow
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                let json = try await request(URL(string: "https://api.jikan.moe/v4/anime/\(malID)/episodes?page=\(jikanPage)")!)
                guard let rows = json["data"] as? [[String: Any]] else { throw KairoError.message("Unexpected episode metadata.") }
                items += rows.compactMap(EpisodeMetadata.jikanEpisode)
                let pagination = json["pagination"] as? [String: Any]
                if rows.isEmpty || pagination?["has_next_page"] as? Bool == false { break }
                }
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

    private func matchingMedia(_ anime: Anime) async throws -> (Int?, [EpisodeMetadata]) {
        let query = "query($title:String){Page(page:1,perPage:8){media(search:$title,type:ANIME){idMal title{english romaji} streamingEpisodes{title thumbnail}}}}"
        let json = try await request(URL(string: "https://graphql.anilist.co")!,
                                     body: ["query": query, "variables": ["title": anime.title]])
        let rows = ((json["data"] as? [String: Any])?["Page"] as? [String: Any])?["media"] as? [[String: Any]] ?? []
        let knownNames = [anime.title, anime.alternateTitle].compactMap { $0 }.map(Self.normalized)
        guard let row = rows.first(where: { row in
            let titles = row["title"] as? [String: Any] ?? [:]
            return [titles["english"], titles["romaji"]].compactMap { $0 as? String }
                .contains(where: { knownNames.contains(Self.normalized($0)) })
        }) else { return (nil, []) }
        let episodes = (row["streamingEpisodes"] as? [[String: Any]] ?? []).compactMap(EpisodeMetadata.streamingEpisode)
        return (row["idMal"] as? Int, episodes)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
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
