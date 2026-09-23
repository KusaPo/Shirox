import Foundation

enum AudioChoice: String, Codable, CaseIterable, Identifiable {
    case sub, dub
    var id: String { rawValue }
    var label: String { self == .sub ? "Original / Sub" : "English dub" }
}

struct Anime: Codable, Identifiable, Hashable {
    var anilistID: Int?
    var malID: Int?
    var sourceID: String?
    var title: String
    var alternateTitle: String?
    var cover: URL?
    var banner: URL?
    var synopsis: String = ""
    var episodeCount: Int?
    var year: Int?
    var genres: [String] = []
    var id: String { anilistID.map { "anilist:\($0)" } ?? "animex:\(sourceID ?? title)" }
}

struct StreamOption: Identifiable {
    var id: String
    var provider: String
    var url: URL
    var headers: [String: String]
    var audio: AudioChoice
    var label: String
    var isHLS: Bool { url.pathExtension.lowercased() == "m3u8" }
}

struct WatchProgress: Codable, Identifiable {
    var anime: Anime
    var episode: Int
    var seconds: Double
    var duration: Double
    var updated: Date = Date()
    var finished: Bool = false
    var id: String { Self.key(anime.id, episode) }
    static func key(_ title: String, _ episode: Int) -> String { "\(title)|episode:\(episode)" }
}

enum DownloadState: String, Codable {
    case queued, resolving, downloading, paused, interrupted, ready
    var label: String { rawValue.capitalized }
}

struct DownloadRecord: Codable, Identifiable {
    var id = UUID()
    var anime: Anime
    var episode: Int
    var audio: AudioChoice
    var provider: String? = nil
    var state: DownloadState = .queued
    var fraction: Double = 0
    var relativePath: String?
    var message: String?
    var created = Date()
    var localURL: URL? {
        guard let relativePath else { return nil }
        return LocalDownloadStorage.url(forRelativePath: relativePath)
    }
}

enum LocalDownloadStorage {
    static var root: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    // iOS can return /private/var/... while the app's home uses /var/....
    // Resolve both URLs before comparing components; never move an HLS package.
    static func relativePath(for location: URL, within root: URL = LocalDownloadStorage.root) -> String? {
        guard location.isFileURL, root.isFileURL else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let target = location.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard target.count > base.count, target.starts(with: base) else { return nil }
        return target.dropFirst(base.count).joined(separator: "/")
    }

    static func url(forRelativePath path: String, within root: URL = LocalDownloadStorage.root) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else { return nil }
        let location = root.appendingPathComponent(path)
        guard relativePath(for: location, within: root) != nil else { return nil }
        return location.resolvingSymlinksInPath().standardizedFileURL
    }
}

struct Preferences: Codable {
    var audio: AudioChoice = .sub
    var wifiOnly = true
    var animexEnabled = true
}

struct SavedState: Codable {
    var library: [Anime] = []
    var progress: [WatchProgress] = []
    var downloads: [DownloadRecord] = []
    var preferences = Preferences()
    var trending: [Anime] = []
    var trendingUpdated: Date?
}

enum KairoError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum WebAddress {
    static func media(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, let host = url.host?.lowercased(),
              host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return url
    }
}
