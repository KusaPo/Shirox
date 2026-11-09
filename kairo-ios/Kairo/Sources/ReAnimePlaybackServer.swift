import Foundation
import Network

/// Device-local media adapter. Only a loopback listener and opaque, registered
/// resource IDs are exposed. Downloads never use this listener: they go directly
/// to the CDN through the OS background session, then unwrap bytes on delivery.
@MainActor final class ReAnimePlaybackServer {
    static let shared = ReAnimePlaybackServer()
    private var listener: NWListener?
    private var startup: Task<UInt16, Error>?
    private let capability = UUID().uuidString
    private var resources: [String: (URL, ReAnimeMedia)] = [:]
    private var identifiers: [String: String] = [:]
    private let session: URLSession
    private var active = 0
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration, delegate: ReAnimeRedirects(), delegateQueue: nil)
    }
    func playbackURL(_ media: ReAnimeMedia) async throws -> URL {
        let port = try await start()
        return try register(media.url, media: media, port: port)
    }
    private func register(_ url: URL, media: ReAnimeMedia, port: UInt16) throws -> URL {
        guard ReAnimeMedia.permits(url) else { throw KairoError.message("ReAnime's playlist uses an unsupported media host.") }
        let key = url.absoluteString + "|" + (media.playlistKey?.base64EncodedString() ?? "")
        let id: String
        if let existing = identifiers[key] { id = existing }
        else {
            guard resources.count < 20000 else { throw KairoError.message("Reopen Kairo to release old ReAnime playback resources.") }
            id = UUID().uuidString
            identifiers[key] = id; resources[id] = (url, media)
        }
        let suffix = url.pathExtension.lowercased() == "m3u8" ? "playlist.m3u8" : "media.bin"
        return URL(string: "http://127.0.0.1:\(port)/\(capability)/\(id)/\(suffix)")!
    }
    private func start() async throws -> UInt16 {
        if let startup { return try await startup.value }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let server = try NWListener(using: parameters); listener = server
        server.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            Self.read(connection, bytes: Data()) { request in
                Task { @MainActor [weak self] in
                    guard let self else { connection.cancel(); return }
                    await self.respond(connection, request: request)
                }
            }
        }
        let task = Task<UInt16, Error> {
            try await withCheckedThrowingContinuation { continuation in
                var finished = false
                // Listener state callbacks are serialized on the main queue.
                server.stateUpdateHandler = { state in
                    guard !finished else { return }
                    switch state {
                    case .ready:
                        if let port = server.port { finished = true; continuation.resume(returning: port.rawValue) }
                    case .failed(let error): finished = true; continuation.resume(throwing: error)
                    case .cancelled: finished = true; continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
                server.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    guard !finished else { return }; finished = true; server.cancel()
                    continuation.resume(throwing: KairoError.message("ReAnime's on-device player could not start."))
                }
            }
        }
        startup = task
        do { return try await task.value }
        catch { startup = nil; listener?.cancel(); listener = nil; throw error }
    }
    nonisolated private static func read(_ connection: NWConnection, bytes: Data, completion: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, finished, error in
            var all = bytes; if let data { all.append(data) }
            guard error == nil, all.count <= 32768 else { connection.cancel(); return }
            if all.range(of: Data("\r\n\r\n".utf8)) != nil { completion(all) }
            else if finished { connection.cancel() }
            else { read(connection, bytes: all, completion: completion) }
        }
    }
    private func respond(_ connection: NWConnection, request: Data) async {
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])),
              let path = String(first[1]).removingPercentEncoding else { Self.send(connection, status: "400 Bad Request"); return }
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == capability, let (url, media) = resources[String(parts[1])],
              active < 12 else { Self.send(connection, status: "404 Not Found"); return }
        active += 1; defer { active -= 1 }
        do {
            var upstream = URLRequest(url: url); upstream.allHTTPHeaderFields = ReAnimeMedia.headers
            let (data, response) = try await session.data(for: upstream)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let final = http.url, ReAnimeMedia.permits(final), !data.isEmpty, data.count <= 32 * 1024 * 1024 else {
                Self.send(connection, status: "502 Bad Gateway"); return
            }
            var bytes: Data, type: String
            if url.pathExtension.lowercased() == "m3u8" {
                guard data.count < 2_000_000, let port = listener?.port?.rawValue else { throw URLError(.badServerResponse) }
                let text = try media.playlist(data)
                let rewritten = try rewrite(text, base: final, media: media, port: port)
                bytes = Data(rewritten.utf8); type = "application/vnd.apple.mpegurl"
            } else if url.pathExtension.lowercased() == "bin" || url.pathExtension.lowercased() == "key" {
                bytes = data; type = "application/octet-stream"
            } else {
                bytes = ReAnimeMedia.unwrap(data); type = "video/mp2t"
            }
            var status = "200 OK", headers = ["Content-Type": type, "Cache-Control": "no-store", "Accept-Ranges": "bytes"]
            if let line = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
                let range = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                guard let bounds = Self.byteRange(range, count: bytes.count) else {
                    Self.send(connection, status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(bytes.count)"]); return
                }
                headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(bytes.count)"
                bytes = bytes.subdata(in: bounds); status = "206 Partial Content"
            }
            headers["Content-Length"] = String(bytes.count)
            Self.send(connection, status: status, headers: headers, body: first[0] == "HEAD" ? Data() : bytes)
        } catch { Self.send(connection, status: "502 Bad Gateway") }
    }
    private func rewrite(_ text: String, base: URL, media: ReAnimeMedia, port: UInt16) throws -> String {
        let regex = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        return try text.components(separatedBy: .newlines).map { line in
            if !line.hasPrefix("#") {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                guard let url = URL(string: line.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
                return try register(url, media: media, port: port).absoluteString
            }
            var result = line
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let valueRange = Range(match.range(at: 1), in: line), let full = Range(match.range, in: result),
                      let url = URL(string: String(line[valueRange]), relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
                result.replaceSubrange(full, with: "URI=\"\(try register(url, media: media, port: port).absoluteString)\"")
            }
            return result
        }.joined(separator: "\n")
    }
    nonisolated static func byteRange(_ value: String, count: Int) -> Range<Int>? {
        guard count > 0, value.hasPrefix("bytes="), !value.contains(",") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int(parts[1]), suffix > 0 { return max(0, count - suffix)..<count }
        guard let start = Int(parts[0]), start >= 0, start < count else { return nil }
        let end: Int
        if parts[1].isEmpty { end = count - 1 }
        else { guard let number = Int(parts[1]), number >= start else { return nil }; end = min(count - 1, number) }
        return start..<(end + 1)
    }
    nonisolated private static func send(_ connection: NWConnection, status: String, headers: [String: String] = [:], body: Data = Data()) {
        var headers = headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = String(body.count) }
        var data = Data(("HTTP/1.1 \(status)\r\nConnection: close\r\n" + headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
