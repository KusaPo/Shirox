import Foundation
import CryptoKit

struct DownloadRetryPolicy {
    static func delay(attempt: Int, retryAfter: String?, now: Date = Date()) -> TimeInterval {
        let floor = min(60, pow(2, Double(min(attempt, 6))))
        if let retryAfter, let seconds = Double(retryAfter), seconds.isFinite, seconds >= 0 {
            return max(floor, seconds)
        }
        if let retryAfter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            if let date = formatter.date(from: retryAfter) { return max(floor, date.timeIntervalSince(now)) }
        }
        return floor
    }
}

/// All episodes share one lane per host, including the cooldown after a 429.
/// Polling keeps cancellation immediate without orphaned continuation waiters.
actor DownloadHostGate {
    static let shared = DownloadHostGate()
    private var active = Set<String>()
    private var nextAllowed: [String: Date] = [:]
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    init(now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(for: .seconds(seconds))
         }) {
        self.now = now; self.sleep = sleep
    }
    func acquire(_ host: String) async throws {
        while true {
            try Task.checkCancellation()
            let wait = (nextAllowed[host] ?? .distantPast).timeIntervalSince(now())
            if !active.contains(host), wait <= 0 { active.insert(host); return }
            try await sleep(min(max(wait, 0.05), 0.25))
        }
    }
    func release(_ host: String, cooldown: TimeInterval = 0.15) {
        active.remove(host)
        nextAllowed[host] = max(nextAllowed[host] ?? .distantPast, now().addingTimeInterval(cooldown))
    }
}

/// HTTP status is inspected before a response can become media on disk.
actor DownloadHTTPClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let gate: DownloadHostGate
    init(wifiOnly: Bool = true, gate: DownloadHostGate = .shared, transport: Transport? = nil) {
        self.gate = gate
        if let transport { self.transport = transport }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.allowsCellularAccess = !wifiOnly
            config.waitsForConnectivity = true
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            config.httpMaximumConnectionsPerHost = 1
            let session = URLSession(configuration: config)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw KairoError.message("The media server returned an invalid response.") }
                return (data, http)
            }
        }
    }
    static func headers(for url: URL, supplied: [String: String]) -> [String: String] {
        var headers = supplied
        let names = Set(supplied.keys.map { $0.lowercased() })
        if !names.contains("user-agent") {
            headers["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        }
        if !names.contains("referer"), var origin = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            origin.path = "/"; origin.query = nil; origin.fragment = nil
            origin.user = nil; origin.password = nil
            headers["Referer"] = origin.url?.absoluteString
        }
        return headers
    }
    func fetch(_ url: URL, headers: [String: String], range: HLSByteRange? = nil,
               onWait: @escaping @Sendable (TimeInterval) -> Void = { _ in }) async throws -> (Data, URL) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host else {
            throw KairoError.message("The playlist contains an unsupported media address.")
        }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = Self.headers(for: url, supplied: headers)
        if let range {
            guard range.offset >= 0, range.length > 0, range.offset <= Int.max - range.length else {
                throw KairoError.message("The playlist contains an invalid byte range.")
            }
            request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range")
        }
        for attempt in 1...7 {
            try await gate.acquire(host)
            let data: Data
            let response: HTTPURLResponse
            do { (data, response) = try await transport(request) }
            catch {
                await gate.release(host)
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
            let status = response.statusCode
            if [429, 503].contains(status) {
                let delay = DownloadRetryPolicy.delay(attempt: attempt, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
                await gate.release(host, cooldown: delay)
                guard attempt < 7 else { throw KairoError.message("The media server is still limiting requests (HTTP \(status)). Your completed segments are saved; retry later.") }
                onWait(delay)
                continue
            }
            await gate.release(host)
            guard (200..<300).contains(status), !data.isEmpty else {
                throw KairoError.message("The media server returned HTTP \(status). Completed segments are kept for retry.")
            }
            if let range {
                if status == 206 {
                    guard data.count == range.length,
                          response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(range.offset)-\(range.offset + range.length - 1)/") == true else {
                        throw KairoError.message("The media server returned an incorrect byte range.")
                    }
                    return (data, response.url ?? url)
                }
                guard data.count >= range.offset + range.length else { throw KairoError.message("The media server returned an incomplete segment.") }
                return (data.subdata(in: range.offset..<(range.offset + range.length)), response.url ?? url)
            }
            return (data, response.url ?? url)
        }
        throw KairoError.message("The download retry limit was reached.")
    }
}

/// Stores standard on-demand HLS with local-only manifests. Network work is sequential per
/// episode and coordinated per host, so two queued episodes cannot overwhelm one CDN.
actor HLSDownloadTransfer {
    private let client: DownloadHTTPClient
    private var keys: [URL: Data] = [:]
    init(client: DownloadHTTPClient) { self.client = client }
    func download(url: URL, headers: [String: String], folder: URL,
                  onProgress: @escaping @Sendable (Double) -> Void,
                  onWait: @escaping @Sendable (TimeInterval) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var (text, base) = try await manifest(url, headers: headers, onWait: onWait)
        var audio: [(HLSAudioRendition, String, URL)] = []
        var choice: HLSVariantChoice?
        if text.contains("#EXT-X-STREAM-INF") {
            guard let selected = HLSManifestParser.selectBestVariantChoice(text, baseURL: base) else { throw KairoError.message("No downloadable HLS variant was found.") }
            choice = selected
            (text, base) = try await manifest(selected.video, headers: headers, onWait: onWait)
            for rendition in selected.audioRenditions {
                let (content, origin) = try await manifest(rendition.url, headers: headers, onWait: onWait)
                audio.append((rendition, content, origin))
            }
        }
        let video = try plan(text, base: base)
        let audioPlans = try audio.map { ($0.0, try plan($0.1, base: $0.2)) }
        let total = video.segments.count + audioPlans.reduce(0) { $0 + $1.1.segments.count }
        var completed = 0
        func progress() { completed += 1; onProgress(Double(completed) / Double(total)) }
        let videoText = try await rendition(video, prefix: "v_", folder: folder, headers: headers, onWait: onWait, progress: progress)
        let target = folder.appendingPathComponent("playlist.m3u8")
        if let choice, !audioPlans.isEmpty {
            try videoText.write(to: folder.appendingPathComponent("video.m3u8"), atomically: true, encoding: .utf8)
            var localAudio: [HLSLocalAudio] = []
            for (index, pair) in audioPlans.enumerated() {
                let name = "audio_\(index).m3u8"
                let content = try await rendition(pair.1, prefix: "a\(index)_", folder: folder, headers: headers, onWait: onWait, progress: progress)
                try content.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
                localAudio.append(HLSLocalAudio(playlist: name, name: pair.0.name, language: pair.0.language, isDefault: pair.0.isDefault))
            }
            try HLSManifestParser.localMasterManifest(videoPlaylist: "video.m3u8", audio: localAudio, bandwidth: choice.bandwidth, codecs: choice.codecs)
                .write(to: target, atomically: true, encoding: .utf8)
        } else { try videoText.write(to: target, atomically: true, encoding: .utf8) }
        try Task.checkCancellation()
        return target
    }
    func prepareBackground(id: UUID, url: URL, headers: [String: String], folder: URL, wifiOnly: Bool) async throws -> BackgroundHLSJob {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        var (text, base) = try await manifest(url, headers: headers, onWait: { _ in })
        var choice: HLSVariantChoice?
        var audio: [(HLSAudioRendition, HLSDownloadPlan)] = []
        if text.contains("#EXT-X-STREAM-INF") {
            guard let selected = HLSManifestParser.selectBestVariantChoice(text, baseURL: base) else { throw KairoError.message("No downloadable HLS variant was found.") }
            choice = selected
            (text, base) = try await manifest(selected.video, headers: headers, onWait: { _ in })
            for rendition in selected.audioRenditions {
                let (content, origin) = try await manifest(rendition.url, headers: headers, onWait: { _ in })
                audio.append((rendition, try plan(content, base: origin)))
            }
        }
        let video = try plan(text, base: base)
        var resources: [BackgroundHLSResource] = []
        func collect(_ plan: HLSDownloadPlan, prefix: String) async throws -> String {
            let original = plan.segments[0].url.pathExtension.lowercased()
            let ext = plan.isFMP4 ? "m4s" : (["aac", "mp3", "ac3", "ec3"].contains(original) ? original : "ts")
            var initName: String?
            if let start = plan.initSegment {
                initName = prefix + "init.mp4"
                resources.append(try await backgroundResource(start.url, name: initName!, range: start.byteRange, key: start.key, sequence: 0, headers: headers))
            }
            for (index, segment) in plan.segments.enumerated() {
                try Task.checkCancellation()
                resources.append(try await backgroundResource(segment.url, name: "\(prefix)seg_\(index).\(ext)", range: segment.byteRange, key: segment.key, sequence: segment.mediaSequence, headers: headers))
            }
            return HLSManifestParser.localManifest(durations: plan.segments.map(\.duration), segmentExtension: ext, initFileName: initName, segmentPrefix: prefix + "seg_")
        }
        let videoText = try await collect(video, prefix: "v_")
        var manifests: [String: String] = [:]
        if let choice, !audio.isEmpty {
            manifests["video.m3u8"] = videoText
            var localAudio: [HLSLocalAudio] = []
            for (index, pair) in audio.enumerated() {
                let name = "audio_\(index).m3u8"
                manifests[name] = try await collect(pair.1, prefix: "a\(index)_")
                localAudio.append(HLSLocalAudio(playlist: name, name: pair.0.name, language: pair.0.language, isDefault: pair.0.isDefault))
            }
            manifests["playlist.m3u8"] = HLSManifestParser.localMasterManifest(videoPlaylist: "video.m3u8", audio: localAudio, bandwidth: choice.bandwidth, codecs: choice.codecs)
        } else { manifests["playlist.m3u8"] = videoText }
        for index in resources.indices { resources[index].complete = resources[index].exists(in: folder) }
        return BackgroundHLSJob(id: id, wifiOnly: wifiOnly, headers: headers, resources: resources, manifests: manifests)
    }
    private func backgroundResource(_ url: URL, name: String, range: HLSByteRange?, key: HLSKey?, sequence: Int, headers: [String: String]) async throws -> BackgroundHLSResource {
        let identity = "\(url.absoluteString)|\(String(describing: range))|\(String(describing: key))|\(sequence)"
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        var keyData: Data?, iv: Data?
        if let key {
            guard key.method == .aes128, let address = key.url else { throw KairoError.message("Unsupported HLS encryption.") }
            if let cached = keys[address] { keyData = cached }
            else {
                let bytes = try await client.fetch(address, headers: headers).0
                guard bytes.count == 16 else { throw KairoError.message("Invalid HLS encryption key.") }
                keys[address] = bytes; keyData = bytes
            }
            iv = Data(key.iv ?? HLSManifestParser.defaultIV(forMediaSequence: sequence))
        }
        return BackgroundHLSResource(url: url, name: name, range: range, key: keyData, iv: iv, identity: hash)
    }
    private func manifest(_ url: URL, headers: [String: String], onWait: @escaping @Sendable (TimeInterval) -> Void) async throws -> (String, URL) {
        let (data, final) = try await client.fetch(url, headers: headers, onWait: onWait)
        guard let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            throw KairoError.message("The source returned a page instead of a standard HLS playlist.")
        }
        return (text, final)
    }
    private func plan(_ text: String, base: URL) throws -> HLSDownloadPlan {
        // These need richer timeline/encryption support. Reject before silently losing it.
        guard text.contains("#EXT-X-ENDLIST"), !text.contains("#EXT-X-DISCONTINUITY"), !text.contains("#EXT-X-GAP"),
              text.components(separatedBy: "#EXT-X-MAP:").count <= 2 else {
            throw KairoError.message("This playlist uses a live or changing timeline that offline downloads do not yet support. Try another provider.")
        }
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("#EXT-X-KEY:") {
            guard line.contains("METHOD=NONE") || (line.contains("METHOD=AES-128") && !line.contains("KEYFORMAT=")) else {
                throw KairoError.message("This provider's encryption is not supported for offline saving.")
            }
        }
        let result = HLSManifestParser.parseMediaPlaylist(text, baseURL: base)
        guard !result.segments.isEmpty, result.segments.allSatisfy({ $0.duration.isFinite && $0.duration > 0 }) else {
            throw KairoError.message("The episode playlist is incomplete.")
        }
        return result
    }
    private func rendition(_ plan: HLSDownloadPlan, prefix: String, folder: URL, headers: [String: String],
                           onWait: @escaping @Sendable (TimeInterval) -> Void, progress: () -> Void) async throws -> String {
        let original = plan.segments[0].url.pathExtension.lowercased()
        let ext = plan.isFMP4 ? "m4s" : (["aac", "mp3", "ac3", "ec3"].contains(original) ? original : "ts")
        var initName: String?
        if let start = plan.initSegment {
            initName = prefix + "init.mp4"
            try await resource(start.url, range: start.byteRange, key: start.key, sequence: 0,
                               target: folder.appendingPathComponent(initName!), headers: headers, onWait: onWait)
        }
        for (index, segment) in plan.segments.enumerated() {
            try Task.checkCancellation()
            try await resource(segment.url, range: segment.byteRange, key: segment.key, sequence: segment.mediaSequence,
                               target: folder.appendingPathComponent("\(prefix)seg_\(index).\(ext)"), headers: headers, onWait: onWait)
            progress()
        }
        return HLSManifestParser.localManifest(durations: plan.segments.map(\.duration), segmentExtension: ext, initFileName: initName, segmentPrefix: prefix + "seg_")
    }
    private func resource(_ url: URL, range: HLSByteRange?, key: HLSKey?, sequence: Int, target: URL,
                          headers: [String: String], onWait: @escaping @Sendable (TimeInterval) -> Void) async throws {
        // Identity includes the key, IV, sequence and range: a renewed signed URL never reuses
        // unrelated old bytes just because the segment has the same list index.
        let identity = "\(url.absoluteString)|\(String(describing: range))|\(String(describing: key))|\(sequence)"
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let marker = target.appendingPathExtension("sha256")
        if let saved = try? String(contentsOf: marker, encoding: .utf8), saved == hash,
           let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 { return }
        var (data, _) = try await client.fetch(url, headers: headers, range: range, onWait: onWait)
        if let key {
            guard key.method == .aes128, let address = key.url else { throw KairoError.message("Unsupported HLS encryption.") }
            let keyData: Data
            if let cached = keys[address] { keyData = cached }
            else {
                keyData = try await client.fetch(address, headers: headers, onWait: onWait).0
                keys[address] = keyData
            }
            guard let clear = HLSManifestParser.decryptAES128CBC(data, key: keyData, iv: Data(key.iv ?? HLSManifestParser.defaultIV(forMediaSequence: sequence))) else {
                throw KairoError.message("The HLS segment could not be decoded.")
            }
            data = clear
        }
        let beginning = String(decoding: data.prefix(128), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !beginning.hasPrefix("<!doctype"), !beginning.hasPrefix("<html") else { throw KairoError.message("The media server returned an error page instead of video.") }
        try Task.checkCancellation()
        try data.write(to: target, options: .atomic)
        try hash.write(to: marker, atomically: true, encoding: .utf8)
    }
}
