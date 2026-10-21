import Foundation
import Network

/// AVPlayer reads local HLS over loopback; only registered episode directories are exposed.
/// A random per-process capability and loopback binding keep files off the LAN.
@MainActor final class OfflineHLSServer {
    static let shared = OfflineHLSServer()
    private var listener: NWListener?
    private var startup: Task<UInt16, Error>?
    private let token = UUID().uuidString
    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kairo/Downloads", isDirectory: true)
    }
    func playbackURL(for local: URL) async throws -> URL {
        guard local.isFileURL, local.pathExtension.lowercased() == "m3u8" else { return local }
        let root = self.root.resolvingSymlinksInPath().standardizedFileURL
        let safe = local.resolvingSymlinksInPath().standardizedFileURL
        guard safe.path.hasPrefix(root.path + "/") else { throw KairoError.message("The offline playlist is outside Kairo's download folder.") }
        let port = try await start()
        let relative = String(safe.path.dropFirst(root.path.count + 1))
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(relative)")!
    }
    private func start() async throws -> UInt16 {
        if let startup { return try await startup.value }
        let root = self.root
        let token = self.token
        let task = Task<UInt16, Error> {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let server = try NWListener(using: parameters)
            self.listener = server
            server.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .userInitiated))
                Self.read(connection, bytes: Data(), root: root, token: token)
            }
            return try await withCheckedThrowingContinuation { continuation in
                var completed = false
                server.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard !completed, let port = server.port else { return }
                        completed = true; continuation.resume(returning: port.rawValue)
                    case .failed(let error):
                        guard !completed else { return }
                        completed = true; continuation.resume(throwing: error)
                    case .cancelled:
                        guard !completed else { return }
                        completed = true; continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
                server.start(queue: DispatchQueue(label: "net.kusapo.kairo.offline"))
            }
        }
        startup = task
        do { return try await task.value }
        catch { startup = nil; listener?.cancel(); listener = nil; throw error }
    }
    nonisolated private static func read(_ connection: NWConnection, bytes: Data, root: URL, token: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, finished, error in
            var all = bytes; if let data { all.append(data) }
            guard all.count <= 32_768, error == nil else { connection.cancel(); return }
            if all.range(of: Data("\r\n\r\n".utf8)) != nil {
                respond(connection, request: all, root: root, token: token)
            } else if finished { connection.cancel() }
            else { read(connection, bytes: all, root: root, token: token) }
        }
    }
    nonisolated static func resolve(path: String, root: URL, token: String) -> URL? {
        guard let decoded = path.removingPercentEncoding, decoded.hasPrefix("/\(token)/") else { return nil }
        let relative = String(decoded.dropFirst(token.count + 2))
        guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let file = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path + "/"), ["m3u8", "ts", "m4s", "mp4", "aac", "mp3", "ac3", "ec3"].contains(file.pathExtension.lowercased()) else { return nil }
        return file
    }
    nonisolated private static func respond(_ connection: NWConnection, request: Data, root: URL, token: String) {
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])),
              let file = resolve(path: String(first[1]), root: root, token: token),
              let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
              let size = values.fileSize else { send(connection, status: "404 Not Found", headers: [:], body: Data()); return }
        var lower = 0, upper = max(0, size - 1)
        var partial = false
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let value = rangeLine.dropFirst(6).trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("bytes="), !value.contains(",") else { send(connection, status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(size)"], body: Data()); return }
            let bounds = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if bounds.count == 2, bounds[0].isEmpty, let suffix = Int(bounds[1]), suffix > 0 { lower = max(0, size - suffix) }
            else if bounds.count == 2, let start = Int(bounds[0]), start >= 0 {
                lower = start
                if !bounds[1].isEmpty {
                    guard let end = Int(bounds[1]) else { send(connection, status: "416 Range Not Satisfiable", headers: [:], body: Data()); return }
                    upper = min(upper, end)
                }
            } else { send(connection, status: "416 Range Not Satisfiable", headers: [:], body: Data()); return }
            guard size > 0, lower <= upper, lower < size else { send(connection, status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(size)"], body: Data()); return }
            partial = true
        }
        let count = size == 0 ? 0 : upper - lower + 1
        let types = ["m3u8": "application/vnd.apple.mpegurl", "ts": "video/mp2t", "m4s": "video/iso.segment", "mp4": "video/mp4", "aac": "audio/aac", "mp3": "audio/mpeg", "ac3": "audio/ac3", "ec3": "audio/eac3"]
        var headers = ["Content-Type": types[file.pathExtension] ?? "application/octet-stream", "Content-Length": String(count), "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
        if partial { headers["Content-Range"] = "bytes \(lower)-\(upper)/\(size)" }
        do {
            var body = Data()
            if first[0] != "HEAD", count > 0 {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(lower))
                body = try handle.read(upToCount: count) ?? Data()
                guard body.count == count else { throw CocoaError(.fileReadUnknown) }
            }
            send(connection, status: partial ? "206 Partial Content" : "200 OK", headers: headers, body: body)
        } catch { send(connection, status: "500 Internal Server Error", headers: [:], body: Data()) }
    }
    nonisolated private static func send(_ connection: NWConnection, status: String, headers: [String: String], body: Data) {
        var headers = headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = String(body.count) }
        var content = Data(("HTTP/1.1 \(status)\r\nConnection: close\r\n" + headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8)
        content.append(body)
        connection.send(content: content, completion: .contentProcessed { _ in connection.cancel() })
    }
}
