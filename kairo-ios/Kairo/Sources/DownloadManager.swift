import Foundation
import AVFoundation
import Combine

// Keep AVFoundation's factory result typed. Its private runtime session class
// need not pass a dynamic downcast after being stored as a plain URLSession.
struct DownloadSessions {
    private let wifiHLS: AVAssetDownloadURLSession
    private let anyHLS: AVAssetDownloadURLSession
    private let wifiFile: URLSession
    private let anyFile: URLSession

    init(prefix: String, delegate: (AVAssetDownloadDelegate & URLSessionDownloadDelegate)?) {
        func configuration(_ kind: String, wifiOnly: Bool) -> URLSessionConfiguration {
            let config = URLSessionConfiguration.background(withIdentifier: prefix + kind + (wifiOnly ? ".wifi" : ".any"))
            config.allowsCellularAccess = !wifiOnly
            config.waitsForConnectivity = true
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
            return config
        }
        wifiHLS = AVAssetDownloadURLSession(configuration: configuration("hls", wifiOnly: true), assetDownloadDelegate: delegate, delegateQueue: .main)
        anyHLS = AVAssetDownloadURLSession(configuration: configuration("hls", wifiOnly: false), assetDownloadDelegate: delegate, delegateQueue: .main)
        wifiFile = URLSession(configuration: configuration("file", wifiOnly: true), delegate: delegate, delegateQueue: .main)
        anyFile = URLSession(configuration: configuration("file", wifiOnly: false), delegate: delegate, delegateQueue: .main)
    }

    func hls(wifiOnly: Bool) -> AVAssetDownloadURLSession { wifiOnly ? wifiHLS : anyHLS }
    func file(wifiOnly: Bool) -> URLSession { wifiOnly ? wifiFile : anyFile }
    // Upcasting is only for shared URLSession operations such as restoration.
    var all: [URLSession] { [wifiHLS, anyHLS, wifiFile, anyFile] }
}

// Delegate queues are main queues; published state is mutated on the main thread.
final class DownloadManager: NSObject, ObservableObject, AVAssetDownloadDelegate, URLSessionDownloadDelegate {
    private let store: AppStore
    private lazy var sessions = DownloadSessions(prefix: Self.prefix, delegate: self)
    private var tasks: [UUID: URLSessionTask] = [:]
    private var preparing: [UUID: Task<Void, Never>] = [:]
    private var transferErrors: [UUID: String] = [:]
    private var restoring = true
    static let prefix = "net.kusapo.kairo.download."
    private static let unrecognizedLocation = "Kairo couldn't recognize the saved download location: "
    private static var backgroundCompletions: [String: () -> Void] = [:]
    private static var finishedSessions = Set<String>()
    private static var validations: [String: Int] = [:]

    static func registerCompletion(_ identifier: String, handler: @escaping () -> Void) {
        backgroundCompletions[identifier] = handler
        finishIfReady(identifier)
    }
    private static func finishIfReady(_ identifier: String) {
        guard finishedSessions.contains(identifier), validations[identifier, default: 0] == 0,
              let completion = backgroundCompletions.removeValue(forKey: identifier) else { return }
        finishedSessions.remove(identifier)
        completion()
    }

    init(store: AppStore) {
        self.store = store
        super.init()
        restore()
    }

    private func restore() {
        let oldIDs = Set(store.state.downloads.filter { $0.state != .ready }.map(\.id))
        let allSessions = sessions.all
        var remaining = allSessions.count
        for session in allSessions {
            session.getAllTasks { [weak self] restored in
                DispatchQueue.main.async {
                    guard let self else { return }
                    for task in restored {
                        guard let text = task.taskDescription, let id = UUID(uuidString: text), self.store.state.downloads.contains(where: { $0.id == id }) else { task.cancel(); continue }
                        self.tasks[id] = task
                        self.store.updateDownload(id) { $0.state = task.state == .suspended ? .paused : .downloading }
                    }
                    remaining -= 1
                    guard remaining == 0 else { return }
                    for id in oldIDs where self.tasks[id] == nil {
                        self.store.updateDownload(id) { item in
                            if item.state == .resolving || item.state == .downloading {
                                item.state = .interrupted
                                item.message = "The transfer stopped. Retry to get a fresh episode link."
                            }
                        }
                    }
                    for item in self.store.state.downloads where item.state == .ready {
                        if item.localURL.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
                            self.store.updateDownload(item.id) { $0.state = .interrupted; $0.message = "The saved file is no longer available on this device." }
                        }
                    }
                    self.recoverMisclassifiedDownloads()
                    self.restoring = false
                    self.pump()
                }
            }
        }
    }

    private func recoverMisclassifiedDownloads() {
        for record in store.state.downloads where record.state == .interrupted && record.relativePath == nil {
            guard let message = record.message, message.hasPrefix(Self.unrecognizedLocation) else { continue }
            let path = String(message.dropFirst(Self.unrecognizedLocation.count))
            let original = URL(fileURLWithPath: path)
            guard original.pathExtension.lowercased() == "movpkg",
                  let relativePath = LocalDownloadStorage.relativePath(for: original),
                  let local = LocalDownloadStorage.url(forRelativePath: relativePath),
                  FileManager.default.fileExists(atPath: local.path) else { continue }
            store.updateDownload(record.id) { $0.relativePath = relativePath; $0.state = .resolving; $0.message = "Checking saved episode…" }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let asset = AVURLAsset(url: local)
                    guard try await asset.load(.isPlayable), asset.assetCache?.isPlayableOffline == true else {
                        throw KairoError.message("The saved episode is not available offline. Retry the download.")
                    }
                    guard self.store.state.downloads.contains(where: { $0.id == record.id }) else { return }
                    self.store.updateDownload(record.id) { $0.state = .ready; $0.fraction = 1; $0.message = nil }
                } catch {
                    guard self.store.state.downloads.contains(where: { $0.id == record.id }) else { return }
                    self.store.updateDownload(record.id) { $0.state = .interrupted; $0.message = error.localizedDescription }
                }
            }
        }
    }

    func enqueue(_ anime: Anime, episode: Int, audio: AudioChoice, provider: String? = nil) {
        guard !store.state.downloads.contains(where: { $0.anime.id == anime.id && $0.episode == episode && $0.audio == audio }) else { return }
        store.state.downloads.append(DownloadRecord(anime: anime, episode: episode, audio: audio, provider: provider))
        store.save()
        pump()
    }

    private func pump() {
        guard !restoring else { return }
        while tasks.values.filter({ $0.state == .running }).count + preparing.count < 2 {
            guard let item = store.state.downloads.first(where: { $0.state == .queued && preparing[$0.id] == nil }) else { return }
            if let task = tasks[item.id] {
                store.updateDownload(item.id) { $0.state = .downloading; $0.message = nil }
                task.resume()
            } else {
                store.updateDownload(item.id) { $0.state = .resolving; $0.message = nil }
                preparing[item.id] = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.prepare(item)
                    self.preparing[item.id] = nil
                    self.pump()
                }
            }
        }
    }

    @MainActor private func prepare(_ item: DownloadRecord) async {
        do {
            if let moduleID = item.anime.moduleID {
                let module = try ModuleRegistry.shared.module(moduleID)
                guard module.downloads else { throw KairoError.message("This module does not support downloads.") }
            }
            guard item.anime.moduleID != nil || store.state.preferences.animexEnabled else { throw KairoError.message("Enable Animex in Sources before retrying this download.") }
            let options = try await CatalogAPI.shared.streams(item.anime, episode: item.episode, audio: item.audio)
            guard let stream = options.first(where: { item.provider == nil || $0.provider == item.provider }) else { throw KairoError.message("The selected provider is no longer available. Remove this queue item and select another provider.") }
            try Task.checkCancellation()
            guard store.state.downloads.contains(where: { $0.id == item.id }) else { return }
            let wifiOnly = store.state.preferences.wifiOnly
            let task: URLSessionTask
            if stream.isHLS {
                let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
                guard try await asset.load(.isPlayable) else {
                    throw KairoError.message("This provider's stream cannot be opened by iOS. Try another provider for this episode.")
                }
                let protected = try await asset.load(.hasProtectedContent)
                guard !protected else {
                    throw KairoError.message("This stream requires an offline content license. Kairo does not support downloading it.")
                }
                let duration = try await asset.load(.duration)
                guard duration.seconds.isFinite, duration.seconds > 0 else {
                    throw KairoError.message("iOS could not confirm a completed episode to save. Live or unfinished streams cannot be downloaded. Try another provider.")
                }
                let configuration = AVAssetDownloadConfiguration(asset: asset, title: "\(item.anime.title) · Episode \(item.episode)")
                let preferredSelection = try await asset.load(.preferredMediaSelection)
                // Save the selected embedded caption track, if offered. External subtitle URLs
                // need a separate implementation and are not claimed to be downloaded.
                if let selection = preferredSelection.mutableCopy() as? AVMutableMediaSelection {
                    if let group = try await asset.loadMediaSelectionGroup(for: .audible),
                       let option = AVMediaSelectionGroup.mediaSelectionOptions(from: group.options, with: Locale(identifier: item.audio.languageCode)).first {
                        selection.select(option, in: group)
                    }
                    if let group = try await asset.loadMediaSelectionGroup(for: .legible),
                       let english = AVMediaSelectionGroup.mediaSelectionOptions(from: group.options, with: Locale(identifier: "en")).first {
                        selection.select(english, in: group)
                    }
                    configuration.primaryContentConfiguration.mediaSelections = [selection]
                } else {
                    configuration.primaryContentConfiguration.mediaSelections = [preferredSelection]
                }
                try Task.checkCancellation()
                let session = sessions.hls(wifiOnly: wifiOnly)
                task = session.makeAssetDownloadTask(downloadConfiguration: configuration)
            } else {
                var request = URLRequest(url: stream.url)
                request.allHTTPHeaderFields = stream.headers
                let session = sessions.file(wifiOnly: wifiOnly)
                task = session.downloadTask(with: request)
            }
            task.taskDescription = item.id.uuidString
            tasks[item.id] = task
            store.updateDownload(item.id) { $0.state = .downloading; $0.fraction = 0; $0.message = nil }
            task.resume()
        } catch is CancellationError { /* A pause or removal owns the resulting state. */ }
        catch {
            guard !Task.isCancelled else { return }
            store.updateDownload(item.id) { $0.state = .interrupted; $0.message = Self.failureMessage(error, stage: "Preparing download") }
        }
    }

    private static func failureMessage(_ error: Error, stage: String) -> String {
        if error is KairoError { return error.localizedDescription }
        let failure = error as NSError
        var detail = "\(stage): \(failure.localizedDescription) [\(failure.domain) \(failure.code)]"
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
            detail += " [\(underlying.domain) \(underlying.code)]"
        }
        #if targetEnvironment(simulator)
        detail += " If this repeats in Simulator, test the same provider on your iPhone."
        #endif
        return detail
    }

    func pause(_ id: UUID) {
        preparing[id]?.cancel()
        tasks[id]?.suspend()
        store.updateDownload(id) { $0.state = .paused }
        pump()
    }
    func resume(_ id: UUID) {
        guard preparing[id] == nil else { return }
        store.updateDownload(id) { $0.state = .queued; $0.message = nil }
        pump()
    }
    func remove(_ id: UUID) {
        preparing[id]?.cancel()
        tasks.removeValue(forKey: id)?.cancel()
        if let url = store.state.downloads.first(where: { $0.id == id })?.localURL {
            do { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
            catch { store.updateDownload(id) { $0.message = "The file could not be deleted: \(error.localizedDescription)" }; return }
        }
        store.state.downloads.removeAll { $0.id == id }
        store.save()
        pump()
    }
    private func id(_ task: URLSessionTask) -> UUID? { task.taskDescription.flatMap(UUID.init(uuidString:)) }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = id(assetDownloadTask) else { return }
        let expected = timeRangeExpectedToLoad.duration.seconds
        guard expected.isFinite, expected > 0 else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        store.updateDownload(id) { $0.fraction = min(0.99, max(0, loaded / expected)) }
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        if let id = id(assetDownloadTask) { remember(location, id: id) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = id(downloadTask), totalBytesExpectedToWrite > 0 else { return }
        store.updateDownload(id) { $0.fraction = min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = id(downloadTask) else { return }
        guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { transferErrors[id] = "The media server did not return a successful download."; return }
        do {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kairo/Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(id.uuidString + ".mp4")
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            remember(target, id: id)
        } catch { transferErrors[id] = error.localizedDescription }
    }
    private func remember(_ url: URL, id: UUID) {
        guard let relativePath = LocalDownloadStorage.relativePath(for: url) else {
            // Include the actual local destination so an unexpected system location
            // can be diagnosed instead of incorrectly describing where the file is.
            transferErrors[id] = Self.unrecognizedLocation + url.path
            return
        }
        store.updateDownload(id) { $0.relativePath = relativePath }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = id(task) else { return }
        tasks[id] = nil
        guard let record = store.state.downloads.first(where: { $0.id == id }) else { pump(); return }
        if let message = transferErrors.removeValue(forKey: id) ?? error.map({ Self.failureMessage($0, stage: "Download failed") }) {
            store.updateDownload(id) { $0.state = .interrupted; $0.message = message }
            pump()
            return
        }
        guard let url = record.localURL, FileManager.default.fileExists(atPath: url.path) else {
            store.updateDownload(id) { $0.state = .interrupted; $0.message = "The transfer finished without a usable local file." }
            pump()
            return
        }
        let sessionID = session.configuration.identifier ?? ""
        Self.validations[sessionID, default: 0] += 1
        Task { @MainActor [weak self] in
            defer {
                Self.validations[sessionID, default: 0] -= 1
                Self.finishIfReady(sessionID)
            }
            guard let self else { return }
            let asset = AVURLAsset(url: url)
            do {
                let playable = try await asset.load(.isPlayable)
                let isHLS = task is AVAssetDownloadTask
                guard playable, !isHLS || asset.assetCache?.isPlayableOffline == true else { throw KairoError.message("The saved media is not verified for offline playback. Retry the download.") }
                self.store.updateDownload(id) { $0.state = .ready; $0.fraction = 1; $0.message = nil }
            } catch { self.store.updateDownload(id) { $0.state = .interrupted; $0.message = error.localizedDescription } }
            self.pump()
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Self.finishedSessions.insert(identifier)
        Self.finishIfReady(identifier)
    }
}
