import Foundation
import CryptoKit

struct SubtitleTrack: Codable, Equatable, Identifiable {
    let url: URL
    let label: String
    let format: String
    var id: String { SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() }
    var isEnglish: Bool { label.lowercased().hasPrefix("english") }
    var isForced: Bool { label.lowercased().contains("forced") }
    static func parse(_ row: [String: Any]) -> SubtitleTrack? {
        guard let raw = row["url"] as? String, let url = URL(string: raw), ReAnimeMedia.permits(url),
              let label = row["language"] as? String, !label.isEmpty else { return nil }
        let format = (row["format"] as? String ?? url.pathExtension).lowercased()
        guard ["ass", "ssa", "srt", "vtt", "webvtt"].contains(format) else { return nil }
        return SubtitleTrack(url: url, label: label, format: format)
    }
}
struct SubtitleCue: Codable, Equatable {
    let start: Double
    let end: Double
    let text: String
}
struct SubtitleDocument: Codable, Equatable {
    let track: SubtitleTrack
    let cues: [SubtitleCue]
}
struct SubtitleChoice: Identifiable {
    let id: String
    let label: String
}

enum SubtitleParser {
    static func timestamp(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!), seconds >= 0, seconds < 60,
              let minutes = Double(parts[parts.count - 2]), minutes >= 0, minutes < 60 else { return nil }
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        guard let hours, hours >= 0, hours <= 24 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
    static func parse(_ text: String, format: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{feff}", with: "")
        var cues: [SubtitleCue] = []
        if ["ass", "ssa"].contains(format.lowercased()) {
            var events = false
            var columns = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
            for line in normalized.components(separatedBy: .newlines) {
                if line.hasPrefix("[") { events = line.lowercased() == "[events]"; continue }
                guard events else { continue }
                if line.lowercased().hasPrefix("format:") {
                    columns = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }; continue
                }
                guard line.lowercased().hasPrefix("dialogue:"), columns.last == "text", columns.count >= 3,
                      let startIndex = columns.firstIndex(of: "start"), let endIndex = columns.firstIndex(of: "end") else { continue }
                let values = line.dropFirst(9).split(separator: ",", maxSplits: columns.count - 1, omittingEmptySubsequences: false)
                guard values.count == columns.count, let start = timestamp(String(values[startIndex])), let end = timestamp(String(values[endIndex])) else { continue }
                let raw = String(values.last!)
                // ASS drawing commands are vectors, not dialogue to display.
                guard raw.range(of: #"\\p[1-9]"#, options: .regularExpression) == nil else { continue }
                let body = raw.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
                append(start: start, end: end, text: body, to: &cues)
                if cues.count >= 20000 { break }
            }
        } else {
            for block in normalized.components(separatedBy: "\n\n") {
                let lines = block.components(separatedBy: .newlines)
                guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
                let times = lines[index].components(separatedBy: "-->")
                guard times.count == 2, let start = timestamp(times[0]),
                      let endText = times[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
                      let end = timestamp(String(endText)) else { continue }
                let body = lines.dropFirst(index + 1).joined(separator: "\n")
                    .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
                append(start: start, end: end, text: body, to: &cues)
                if cues.count >= 20000 { break }
            }
        }
        return cues.enumerated().sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }.map(\.element)
    }
    private static func append(start: Double, end: Double, text: String, to cues: inout [SubtitleCue]) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= 90000, !text.isEmpty, text.count <= 10000 else { return }
        cues.append(SubtitleCue(start: start, end: end, text: text))
    }
    static func text(at seconds: Double, cues: [SubtitleCue]) -> String {
        guard seconds.isFinite else { return "" }
        var seen = Set<String>()
        return cues.prefix(while: { $0.start <= seconds }).filter { seconds < $0.end && seen.insert($0.text).inserted }.map(\.text).joined(separator: "\n")
    }
}

actor SubtitleService {
    static let shared = SubtitleService()
    static let archiveName = "kairo-subtitles.json"
    private let session: URLSession
    private var cache: [String: SubtitleDocument] = [:]
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 12; configuration.timeoutIntervalForResource = 18
        session = URLSession(configuration: configuration, delegate: ReAnimeRedirects(), delegateQueue: nil)
    }
    func document(_ track: SubtitleTrack) async throws -> SubtitleDocument {
        if let cached = cache[track.id] { return cached }
        guard ReAnimeMedia.permits(track.url) else { throw KairoError.message("Unsupported subtitle address.") }
        var request = URLRequest(url: track.url); request.allHTTPHeaderFields = ReAnimeMedia.headers
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url.map(ReAnimeMedia.permits) == true, data.count <= 5_000_000,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw KairoError.message("The subtitle track could not be downloaded.")
        }
        let cues = SubtitleParser.parse(text, format: track.format)
        guard !cues.isEmpty else { throw KairoError.message("This subtitle track contains no supported captions.") }
        let document = SubtitleDocument(track: track, cues: cues)
        if cache.count >= 30 { cache.removeAll() }; cache[track.id] = document
        return document
    }
    static func preferred(_ tracks: [SubtitleTrack]) -> SubtitleTrack? {
        let previous = UserDefaults.standard.string(forKey: "playerSubtitleTrack")
        return tracks.first(where: { $0.label == previous })
            ?? tracks.first(where: { $0.isEnglish && !$0.isForced }) ?? tracks.first
    }
    func archive(_ tracks: [SubtitleTrack]) async -> String? {
        let selected = UserDefaults.standard.string(forKey: "playerSubtitleTrack")
        let wanted = Array(tracks.filter { $0.isEnglish || $0.label == selected }.prefix(4))
        let chosen = wanted.isEmpty ? Array(tracks.prefix(1)) : wanted
        let documents = await withTaskGroup(of: SubtitleDocument?.self) { group in
            for track in chosen { group.addTask { try? await self.document(track) } }
            var documents: [SubtitleDocument] = []
            for await result in group { if let result { documents.append(result) } }
            return documents.sorted { $0.track.label < $1.track.label }
        }
        guard !documents.isEmpty, let data = try? JSONEncoder().encode(documents), data.count <= 8_000_000 else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func archiveURL(beside media: URL) -> URL {
        media.pathExtension.lowercased() == "m3u8" ? media.deletingLastPathComponent().appendingPathComponent(archiveName) : media.appendingPathExtension("subtitles.json")
    }
    static func saved(at media: URL) -> [SubtitleDocument] {
        let file = archiveURL(beside: media)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_000_000,
              let bytes = try? Data(contentsOf: file), let documents = try? JSONDecoder().decode([SubtitleDocument].self, from: bytes) else { return [] }
        return documents
    }
    static func save(_ document: SubtitleDocument, beside media: URL) throws {
        var existing = saved(at: media).filter { $0.track.id != document.track.id }; existing.append(document)
        let data = try JSONEncoder().encode(existing)
        guard data.count <= 8_000_000 else { throw KairoError.message("Subtitle archive is too large.") }
        try data.write(to: archiveURL(beside: media), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
