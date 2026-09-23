import Foundation

enum AudioChoice: String, Codable, CaseIterable, Identifiable {
    case sub, dub
    var id: String { rawValue }
    var label: String { self == .sub ? "Original / Sub" : "English dub" }
    var shortLabel: String { self == .sub ? "Sub" : "Dub" }
    var languageCode: String { self == .sub ? "ja" : "en" }
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
    var fraction: Double {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, seconds / duration))
    }
    var summary: String {
        if finished { return "Watched" }
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return "Not started" }
        let position = Self.timestamp(min(max(0, seconds), duration))
        return "\(fraction >= 0.9 ? "Almost finished" : "Continue") · \(position) of \(Self.timestamp(duration))"
    }
    var remainingLabel: String {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return "" }
        return "\(Int(fraction * 100))% watched · \(Self.timestamp(max(0, duration - seconds))) left"
    }
    private static func timestamp(_ seconds: Double) -> String {
        let value = Int(min(max(0, seconds), 359999))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
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
    static func episodeOrder(_ lhs: DownloadRecord, _ rhs: DownloadRecord) -> Bool {
        if lhs.episode != rhs.episode { return lhs.episode < rhs.episode }
        if lhs.audio != rhs.audio { return lhs.audio.rawValue < rhs.audio.rawValue }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum LocalDownloadStorage {
    static var root: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    // Resolve every existing ancestor, including symlinks before a missing leaf.
    // Resolving only the final URL misses an escaping link if its child is absent.
    private static func canonical(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        // System-provided asset URLs may use this root marker. Apple's path
        // semantics make /.nofollow/<path> refer to /<path>.
        let ordinaryPath = path.hasPrefix("/.nofollow/") ? String(path.dropFirst("/.nofollow".count)) : path
        let fm = FileManager.default
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in URL(fileURLWithPath: ordinaryPath).pathComponents.dropFirst() {
            current.appendPathComponent(component)
            if fm.fileExists(atPath: current.path) {
                current = current.resolvingSymlinksInPath().standardizedFileURL
            } else if (try? fm.destinationOfSymbolicLink(atPath: current.path)) != nil {
                // Reject a broken symlink rather than treating it as a safe path.
                return nil
            }
        }
        return current.standardizedFileURL
    }

    // Compare canonical components, retaining only a path within this app's
    // container. HLS packages remain at the location chosen by iOS.
    static func relativePath(for location: URL, within root: URL = LocalDownloadStorage.root) -> String? {
        guard let base = canonical(root)?.pathComponents,
              let target = canonical(location)?.pathComponents else { return nil }
        guard target.count > base.count, target.starts(with: base) else { return nil }
        return target.dropFirst(base.count).joined(separator: "/")
    }

    static func url(forRelativePath path: String, within root: URL = LocalDownloadStorage.root) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else { return nil }
        let location = root.appendingPathComponent(path)
        guard relativePath(for: location, within: root) != nil else { return nil }
        return canonical(location)
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
