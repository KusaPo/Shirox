import Foundation

struct BackgroundHLSResource: Codable {
    var url: URL
    var name: String
    var range: HLSByteRange?
    var key: Data?
    var iv: Data?
    var identity: String
    var complete = false
    var attempts = 0
    var token: String?

    func install(_ location: URL, response: HTTPURLResponse, folder: URL) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw KairoError.message("The media server returned HTTP \(response.statusCode).")
        }
        var bytes = try Data(contentsOf: location)
        if let range {
            guard range.offset >= 0, range.length > 0, range.offset <= Int.max - range.length else {
                throw KairoError.message("Invalid media byte range.")
            }
            if response.statusCode == 206 {
                guard bytes.count == range.length,
                      response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(range.offset)-\(range.offset + range.length - 1)/") == true else {
                    throw KairoError.message("The media server returned an incorrect byte range.")
                }
            } else {
                guard bytes.count >= range.offset + range.length else { throw KairoError.message("Incomplete media byte range.") }
                bytes = bytes.subdata(in: range.offset..<(range.offset + range.length))
            }
        }
        if let key, let iv {
            guard let clear = HLSManifestParser.decryptAES128CBC(bytes, key: key, iv: iv) else { throw KairoError.message("The HLS segment could not be decoded.") }
            bytes = clear
        }
        let start = String(decoding: bytes.prefix(128), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !bytes.isEmpty, !start.hasPrefix("<!doctype"), !start.hasPrefix("<html") else { throw KairoError.message("The server returned an error page instead of media.") }
        try bytes.write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try Data(identity.utf8).write(to: folder.appendingPathComponent(name + ".sha256"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func exists(in folder: URL) -> Bool {
        let target = folder.appendingPathComponent(name)
        return (try? String(contentsOf: target.appendingPathExtension("sha256"), encoding: .utf8)) == identity
            && ((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }
}

struct BackgroundHLSJob: Codable {
    var id: UUID
    var wifiOnly: Bool
    var headers: [String: String]
    var resources: [BackgroundHLSResource]
    var manifests: [String: String]
    var paused = false
    var failure: String?
    var notBefore: [String: Date] = [:]
    var fraction: Double { resources.isEmpty ? 0 : Double(resources.filter(\.complete).count) / Double(resources.count) }
    func finish(in folder: URL) throws -> URL {
        guard !resources.isEmpty, resources.allSatisfy({ $0.complete && $0.exists(in: folder) }) else {
            throw KairoError.message("The saved episode is incomplete.")
        }
        // Publish the entry playlist last, so incomplete downloads cannot look ready.
        for (name, text) in manifests where name != "playlist.m3u8" {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        guard let entry = manifests["playlist.m3u8"] else { throw KairoError.message("The saved playlist is missing.") }
        let target = folder.appendingPathComponent("playlist.m3u8")
        try Data(entry.utf8).write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return target
    }
}

/// Submit the complete episode to the system before suspension. Never depend on an
/// in-process async segment loop or a wakeup for every successive media segment.
/// All delegate calls and journal mutations run on the main queue.
final class BackgroundHLSDownload: NSObject, URLSessionDownloadDelegate {
    static let prefix = DownloadManager.prefix + "segments."
    private let store: AppStore
    private let root: URL
    private var journal: URL { root.appendingPathComponent("background-jobs.json") }
    private var jobs: [UUID: BackgroundHLSJob] = [:]
    private var live: [String: URLSessionDownloadTask] = [:]
    private var nextAllowed: [String: Date] = [:]
    private var readable = true
    var onChange: (() -> Void)?
    private lazy var wifi = session(true)
    private lazy var any = session(false)
    var activeIDs: Set<UUID> { Set(jobs.values.filter { !$0.paused && $0.failure == nil }.map(\.id)) }
    func contains(_ id: UUID) -> Bool { jobs[id] != nil }
    init(store: AppStore, root: URL) {
        self.store = store; self.root = root
        super.init()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            if FileManager.default.fileExists(atPath: journal.path) {
                let saved = try JSONDecoder().decode([BackgroundHLSJob].self, from: Data(contentsOf: journal))
                jobs = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
        } catch { readable = false; store.storageError = "Background downloads could not be restored: \(error.localizedDescription)" }
    }
    private func session(_ wifiOnly: Bool) -> URLSession {
        let c = URLSessionConfiguration.background(withIdentifier: Self.prefix + (wifiOnly ? "wifi" : "any"))
        c.allowsCellularAccess = !wifiOnly; c.waitsForConnectivity = true
        c.isDiscretionary = false; c.sessionSendsLaunchEvents = true
        c.httpMaximumConnectionsPerHost = 1
        c.timeoutIntervalForRequest = 60; c.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }
    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func persist() throws {
        guard readable else { throw KairoError.message("The background download journal could not be opened. Existing data was preserved.") }
        try JSONEncoder().encode(Array(jobs.values)).write(to: journal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func restore(completion: @escaping () -> Void) {
        var remaining = 2
        for session in [wifi, any] {
            session.getAllTasks { [weak self] tasks in
                DispatchQueue.main.async {
                    guard let self else { return }
                    for task in tasks {
                        guard let download = task as? URLSessionDownloadTask, let token = task.taskDescription,
                              let (id, index) = self.find(token), self.jobs[id]?.resources[index].token == token,
                              self.store.state.downloads.contains(where: { $0.id == id }) else { task.cancel(); continue }
                        self.live[token] = download
                    }
                    remaining -= 1
                    guard remaining == 0 else { return }
                    for id in Array(self.jobs.keys) {
                        guard let record = self.store.state.downloads.first(where: { $0.id == id }) else { self.remove(id); continue }
                        if record.state == .paused { self.pause(id); continue }
                        if record.state == .ready { self.remove(id); continue }
                        if self.jobs[id]?.paused == false && self.jobs[id]?.failure == nil {
                            self.schedule(id)
                        }
                    }
                    completion()
                }
            }
        }
    }
    func start(_ job: BackgroundHLSJob) throws {
        let old = jobs[job.id]; jobs[job.id] = job
        do { try persist() } catch { jobs[job.id] = old; throw error }
        schedule(job.id)
    }
    func pause(_ id: UUID) {
        guard jobs[id] != nil else { return }
        jobs[id]?.paused = true
        cancelTasks(id)
        do { try persist() } catch { store.storageError = error.localizedDescription }
    }
    func resume(_ id: UUID) {
        guard jobs[id] != nil else { return }
        jobs[id]?.paused = false; jobs[id]?.failure = nil
        for index in jobs[id]!.resources.indices { jobs[id]?.resources[index].attempts = 0 }
        schedule(id)
    }
    func remove(_ id: UUID) {
        cancelTasks(id); jobs.removeValue(forKey: id)
        do { try persist() } catch { store.storageError = error.localizedDescription }
    }
    private func cancelTasks(_ id: UUID) {
        guard let job = jobs[id] else { return }
        for i in job.resources.indices {
            if let token = job.resources[i].token { live.removeValue(forKey: token)?.cancel() }
            jobs[id]?.resources[i].token = nil
        }
    }
    private func find(_ token: String) -> (UUID, Int)? {
        let bits = token.split(separator: "/")
        guard bits.count == 3, let id = UUID(uuidString: String(bits[0])), let i = Int(bits[1]),
              let job = jobs[id], job.resources.indices.contains(i), job.resources[i].token == token else { return nil }
        return (id, i)
    }
    private func fail(_ id: UUID, _ message: String) {
        jobs[id]?.failure = message; cancelTasks(id)
        try? persist()
        store.updateDownload(id) { $0.state = .interrupted; $0.message = message + " Completed segments are saved; tap retry." }
        onChange?()
    }
    private func schedule(_ id: UUID) {
        guard let job = jobs[id], !job.paused, job.failure == nil else { return }
        do {
            for i in job.resources.indices {
                if jobs[id]!.resources[i].exists(in: folder(id)) { jobs[id]?.resources[i].complete = true; continue }
                jobs[id]?.resources[i].complete = false
                if let token = jobs[id]?.resources[i].token, live[token] != nil { continue }
                let resource = jobs[id]!.resources[i]
                guard ["https", "http"].contains(resource.url.scheme?.lowercased() ?? ""), let host = resource.url.host else { throw KairoError.message("Unsupported media address.") }
                var request = URLRequest(url: resource.url)
                request.allHTTPHeaderFields = DownloadHTTPClient.headers(for: resource.url, supplied: job.headers)
                if let range = resource.range {
                    guard range.offset >= 0, range.length > 0, range.offset <= Int.max - range.length else { throw KairoError.message("Invalid byte range.") }
                    request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range")
                }
                let task = (job.wifiOnly ? wifi : any).downloadTask(with: request)
                let token = "\(id.uuidString)/\(i)/\(UUID().uuidString)"
                task.taskDescription = token; jobs[id]?.resources[i].token = token
                let earliest = max(Date(), nextAllowed[host] ?? .distantPast, job.notBefore[host] ?? .distantPast)
                task.earliestBeginDate = earliest
                nextAllowed[host] = earliest.addingTimeInterval(0.25)
                live[token] = task
            }
            try persist() // Persist identities before handing the whole batch to iOS.
            for resource in jobs[id]!.resources {
                if let token = resource.token { live[token]?.resume() }
            }
            publish(id)
        } catch { fail(id, error.localizedDescription) }
    }
    private func publish(_ id: UUID) {
        guard let job = jobs[id] else { return }
        if job.resources.allSatisfy(\.complete) {
            do {
                let local = try job.finish(in: folder(id))
                guard let relative = LocalDownloadStorage.relativePath(for: local) else { throw KairoError.message("The saved download location is invalid.") }
                store.updateDownload(id) { $0.relativePath = relative; $0.fraction = 1; $0.state = .ready; $0.message = nil }
                jobs.removeValue(forKey: id); try persist(); onChange?()
            } catch { fail(id, error.localizedDescription) }
        } else {
            store.updateDownload(id) { $0.state = .downloading; $0.fraction = min(0.99, job.fraction) }
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let token = downloadTask.taskDescription, let (id, i) = find(token), let job = jobs[id], !job.paused, job.failure == nil else { return }
        guard let response = downloadTask.response as? HTTPURLResponse else { fail(id, "The media server returned an invalid response."); return }
        if [429, 503].contains(response.statusCode) {
            guard job.resources[i].attempts < 6 else { fail(id, "The server is still limiting requests (HTTP \(response.statusCode))."); return }
            let delay = DownloadRetryPolicy.delay(attempt: job.resources[i].attempts + 1, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
            let host = job.resources[i].url.host!
            nextAllowed[host] = max(nextAllowed[host] ?? .distantPast, Date().addingTimeInterval(delay))
            // Cancel/requeue this host's pending batch so existing queued requests also cool down.
            let affected = jobs.values.filter { $0.resources.contains { !$0.complete && $0.url.host == host } }.map(\.id)
            for affectedID in affected {
                jobs[affectedID]?.notBefore[host] = Date().addingTimeInterval(delay)
                for index in jobs[affectedID]!.resources.indices where jobs[affectedID]!.resources[index].url.host == host && !jobs[affectedID]!.resources[index].complete {
                    if let old = jobs[affectedID]?.resources[index].token { live.removeValue(forKey: old)?.cancel() }
                    jobs[affectedID]?.resources[index].token = nil
                }
            }
            jobs[id]?.resources[i].attempts += 1
            for affectedID in affected { schedule(affectedID) }
            store.updateDownload(id) { $0.message = "The server is busy. Retrying automatically after its cooldown." }
            return
        }
        do {
            try job.resources[i].install(location, response: response, folder: folder(id))
            jobs[id]?.resources[i].complete = true; jobs[id]?.resources[i].token = nil
            live.removeValue(forKey: token)
            try persist(); publish(id)
        } catch { fail(id, error.localizedDescription) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let token = task.taskDescription, let (id, _) = find(token) else { return }
        live.removeValue(forKey: token)
        fail(id, "Download failed: \(error.localizedDescription)")
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let identifier = session.configuration.identifier { DownloadManager.finishedBackgroundEvents(identifier) }
    }
}
