import Foundation
import WebKit
import CryptoKit

struct SourceModule: Codable, Identifiable {
    var id: String
    var manifestURL: URL
    var name: String
    var version: String
    var baseURL: URL
    var script: String
    var downloads: Bool
}

struct ModuleEpisode: Codable, Hashable {
    var number: Int
    var href: String
    var title: String?
    var thumbnail: URL?
    var headers: [String: String]
    var metadata: EpisodeMetadata { EpisodeMetadata(number: number, title: title, thumbnail: thumbnail, thumbnailHeaders: headers) }
}

/// Installed code stays on-device. Updating a source is an explicit re-import;
/// failed validation never replaces a working installation.
@MainActor final class ModuleRegistry: ObservableObject {
    static let shared = ModuleRegistry()
    @Published private(set) var modules: [SourceModule] = []
    @Published private(set) var storageError: String?
    private let file: URL
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kairo/modules.json")
        if FileManager.default.fileExists(atPath: self.file.path) {
            do { modules = try JSONDecoder().decode([SourceModule].self, from: Data(contentsOf: self.file)) }
            catch { storageError = "Saved sources could not be read. They have been preserved; restore the source file before making changes." }
        }
    }
    func module(_ id: String) throws -> SourceModule {
        guard let module = modules.first(where: { $0.id == id }) else { throw KairoError.message("This source is no longer installed. Add its manifest link again in Sources.") }
        return module
    }
    func install(_ url: URL) async throws -> SourceModule {
        let (data, _) = try await ModuleNetwork.read(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["sourceName"] as? String, !name.isEmpty,
              let scriptText = json["scriptUrl"] as? String, let scriptURL = WebAddress.media(scriptText),
              let base = json["baseUrl"] as? String, let baseURL = WebAddress.media(base) else {
            throw KairoError.message("Use a Luna/Sora JSON manifest with sourceName, baseUrl and scriptUrl.")
        }
        let (code, _) = try await ModuleNetwork.read(scriptURL)
        guard code.count <= 2_000_000, let script = String(data: code, encoding: .utf8) else { throw KairoError.message("The source script is too large or is not UTF-8 JavaScript.") }
        _ = try await ModuleRunner.execute(script: script, function: "validate", argument: "", timeout: 15)
        let id = "module:" + SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let module = SourceModule(id: id, manifestURL: url, name: name, version: json["version"] as? String ?? "Unknown", baseURL: baseURL, script: script, downloads: json["downloadSupport"] as? Bool ?? false)
        var next = modules.filter { $0.id != id }; next.append(module)
        try persist(next)
        return module
    }
    func remove(_ id: String) throws { try persist(modules.filter { $0.id != id }) }
    private func persist(_ next: [SourceModule]) throws {
        guard storageError == nil else { throw KairoError.message(storageError!) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        modules = next.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// No app cookies, credentials or file URLs are exposed to community code.
final class ModuleRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, WebAddress.media(url.absoluteString) != nil else { completionHandler(nil); return }
        var safe = request
        if response.url?.host != url.host {
            safe.setValue(nil, forHTTPHeaderField: "Authorization")
            safe.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(safe)
    }
}

enum ModuleNetwork {
    static func read(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard WebAddress.media(url.absoluteString) != nil, ["GET", "POST", "HEAD"].contains(method), (body?.utf8.count ?? 0) <= 1_000_000 else {
            throw KairoError.message("This module requested an unsupported network operation.")
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: ModuleRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        request.allHTTPHeaderFields = EpisodeImageResource(url: url, headers: headers).headers
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw KairoError.message("The module server returned no HTTP response.") }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 10_000_000 { throw KairoError.message("The module response exceeded the size limit.") }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, http)
    }
}

/// A disposable WebKit process runs each operation. All requests use the native
/// bridge; CSP blocks page networking and navigation. A hung script can be
/// discarded without blocking the app's UI thread.
@MainActor final class ModuleRunner: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var requestCount = 0
    private var script = ""
    private var function = ""
    private var argument = ""
    static func execute(script: String, function: String, argument: String, timeout: Double = 65) async throws -> String {
        let runner = ModuleRunner()
        return try await runner.run(script: script, function: function, argument: argument, timeout: timeout)
    }
    private func run(script: String, function: String, argument: String, timeout: Double) async throws -> String {
        try Task.checkCancellation()
        self.script = script; self.function = function; self.argument = argument
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()
                config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "network")
                let view = WKWebView(frame: .zero, configuration: config)
                view.navigationDelegate = self; webView = view
                view.loadHTMLString("<html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; connect-src 'none'; form-action 'none'; frame-src 'none'\"></head><body></body></html>", baseURL: nil)
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.finish(.failure(KairoError.message("The source timed out. Its website may be unavailable; retry or choose another source.")))
                }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(KairoError.message("The source script stopped unexpectedly."))) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let code = Self.bridge + "\n" + script + "\n" + """
        const api = {
          searchResults: typeof searchResults === 'function' ? searchResults : null,
          extractDetails: typeof extractDetails === 'function' ? extractDetails : null,
          extractEpisodes: typeof extractEpisodes === 'function' ? extractEpisodes : null,
          extractStreamUrl: typeof extractStreamUrl === 'function' ? extractStreamUrl : null
        };
        if (operation === 'validate') {
          const missing = Object.keys(api).filter(k => !api[k]);
          if (missing.length) throw new Error('Unsupported module: missing ' + missing.join(', '));
          return JSON.stringify(Object.keys(api));
        }
        if (!api[operation]) throw new Error('Unsupported source function: ' + operation);
        let value = await api[operation](input);
        if (typeof value === 'string') value = JSON.parse(value);
        const output = JSON.stringify(value);
        if (!output || output.length > 4000000) throw new Error('Invalid or oversized module result');
        return output;
        """
        webView.callAsyncJavaScript(code, arguments: ["operation": function, "input": argument], in: nil, contentWorld: .page) { [weak self] result in
            switch result {
            case .success(let value):
                if let text = value as? String { self?.finish(.success(text)) }
                else { self?.finish(.failure(KairoError.message("The module returned an unsupported value."))) }
            case .failure(let error):
                let ns = error as NSError
                self?.finish(.failure(KairoError.message("Source script: \(ns.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)")))
            }
        }
    }
    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        for task in requests.values { task.cancel() }; requests.removeAll()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil
        continuation.resume(with: result)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard continuation != nil, function != "validate", requestCount < 100, requests.count < 12,
              let value = message.body as? [String: Any], let text = value["url"] as? String,
              let url = WebAddress.media(text) else { replyHandler(nil, "Source network request is unavailable or invalid."); return }
        requestCount += 1
        let id = UUID()
        requests[id] = Task { [weak self] in
            defer { self?.requests.removeValue(forKey: id) }
            do {
                let (data, response) = try await ModuleNetwork.read(url, method: value["method"] as? String ?? "GET", headers: value["headers"] as? [String: String] ?? [:], body: value["body"] as? String)
                let headers = response.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key).lowercased()] = String(describing: $1.value) }
                replyHandler(["data": String(data: data, encoding: .utf8) ?? "", "status": response.statusCode, "headers": headers, "url": response.url?.absoluteString ?? text], nil)
            } catch { replyHandler(nil, error.localizedDescription) }
        }
    }
    private static let bridge = """
    globalThis.fetchv2 = async function(url, headers = {}, method = 'GET', body = null) {
      const r = await window.webkit.messageHandlers.network.postMessage({url: String(url), headers, method: String(method).toUpperCase(), body});
      return {status:r.status, ok:r.status>=200 && r.status<300, url:r.url, data:r.data,
        headers:{get:(key)=>r.headers[String(key).toLowerCase()] || null},
        text:async()=>r.data, json:async()=>JSON.parse(r.data)};
    };
    globalThis.fetch = (url, options = {}) => fetchv2(url, options.headers || {}, options.method || 'GET', options.body || null);
    globalThis.global = globalThis;
    """
}

actor ModuleCatalog {
    static let shared = ModuleCatalog()
    private var episodeCache: [String: (Date, [ModuleEpisode])] = [:]
    private func call(_ module: SourceModule, _ function: String, _ argument: String) async throws -> Any {
        let result = try await ModuleRunner.execute(script: module.script, function: function, argument: argument)
        return try JSONSerialization.jsonObject(with: Data(result.utf8), options: [.fragmentsAllowed])
    }
    func search(_ query: String, sourceID: String) async throws -> [Anime] {
        let module = try await ModuleRegistry.shared.module(sourceID)
        let value = try await call(module, "searchResults", query)
        guard let rows = value as? [[String: Any]] else { throw KairoError.message("This module returned an unsupported search format.") }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let title = row["title"] as? String, let href = row["href"] as? String, !href.isEmpty, seen.insert(href).inserted else { return nil }
            var anime = Anime(sourceID: href, title: title, cover: EpisodeImageResource.parse(row["image"])?.url)
            anime.moduleID = module.id; anime.moduleName = module.name
            return anime
        }
    }
    func episodes(_ anime: Anime) async throws -> [ModuleEpisode] {
        guard let id = anime.moduleID, let href = anime.sourceID else { return [] }
        let module = try await ModuleRegistry.shared.module(id)
        let key = anime.id + "|" + module.version + "|" + String(module.script.hashValue)
        if let cached = episodeCache[key], Date().timeIntervalSince(cached.0) < 600 { return cached.1 }
        let value = try await call(module, "extractEpisodes", href)
        guard let rows = value as? [[String: Any]] else { throw KairoError.message("This module returned an unsupported episode format.") }
        let episodes = Self.parseEpisodes(rows)
        guard !episodes.isEmpty else { throw KairoError.message("\(module.name) returned no episodes. Its website may be unavailable or the module may need updating.") }
        episodeCache[key] = (Date(), episodes)
        return episodes
    }
    static func parseEpisodes(_ rows: [[String: Any]]) -> [ModuleEpisode] {
        var seen = Set<Int>()
        return rows.compactMap { row in
            // No invented numbering: decimal specials cannot be represented by this player's Int episode IDs.
            guard let raw = CatalogAPI.identifier(row["number"]), let number = Int(raw), number > 0,
                  let href = row["href"] as? String, !href.isEmpty, seen.insert(number).inserted else { return nil }
            let resource = EpisodeImageResource.parse(row["thumbnail"] ?? row["image"], headers: row["thumbnailHeaders"] as? [String: String] ?? [:])
            return ModuleEpisode(number: number, href: href, title: row["title"] as? String, thumbnail: resource?.url, headers: resource?.headers ?? [:])
        }.sorted { $0.number < $1.number }
    }
    func resolve(_ anime: Anime) async throws -> Anime {
        guard let id = anime.moduleID, let href = anime.sourceID else { return anime }
        let module = try await ModuleRegistry.shared.module(id)
        var result = anime
        let episodes = try await episodes(anime)
        result.moduleEpisodes = episodes; result.episodeCount = episodes.last?.number
        if let rows = try? await call(module, "extractDetails", href) as? [[String: Any]], let detail = rows.first {
            result.synopsis = (detail["description"] as? String ?? result.synopsis).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        return result
    }
    func streams(_ anime: Anime, episode: Int, audio: AudioChoice) async throws -> [StreamOption] {
        guard let id = anime.moduleID else { return [] }
        let module = try await ModuleRegistry.shared.module(id)
        let list = try await episodes(anime)
        guard let selected = list.first(where: { $0.number == episode }) else { throw KairoError.message("This source does not list episode \(episode).") }
        let value = try await call(module, "extractStreamUrl", selected.href)
        let streams = Self.parseStreams(value, module: module, audio: audio)
        guard !streams.isEmpty else { throw KairoError.message("\(module.name) returned no playable \(audio.label) streams. Try another audio option or update the module.") }
        return streams
    }
    static func parseStreams(_ value: Any, module: SourceModule, audio: AudioChoice) -> [StreamOption] {
        let object = value as? [String: Any] ?? [:]
        let rows = object["streams"] as? [[String: Any]] ?? (value as? [[String: Any]]) ?? [object]
        return rows.enumerated().compactMap { index, row in
            guard let text = row["streamUrl"] as? String ?? row["url"] as? String ?? (value as? String), let url = WebAddress.media(text),
                  ["m3u8", "mp4", "m4v"].contains(url.pathExtension.lowercased()) else { return nil }
            let label = row["title"] as? String ?? row["quality"] as? String ?? module.name
            let language = ((row["audio"] as? String ?? "") + " " + label).lowercased()
            let providedAudio: AudioChoice = language.contains("dub") || language.contains("english") ? .dub : .sub
            guard providedAudio == audio else { return nil }
            let headers = EpisodeImageResource(url: url, headers: row["headers"] as? [String: String] ?? object["headers"] as? [String: String] ?? [:]).headers
            return StreamOption(id: "\(module.id):\(index)", provider: label, url: url, headers: headers, audio: providedAudio, label: label,
                                preview: EpisodeImageResource.parse(row["thumbnail"]))
        }
    }
}
