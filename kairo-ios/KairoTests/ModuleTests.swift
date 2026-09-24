import XCTest
@testable import Kairo

final class ModuleTests: XCTestCase {
    private let script = """
    async function searchResults(q) { await new Promise(r => setTimeout(r, 5)); return JSON.stringify([{title:q,href:'fixture://series'}]); }
    function extractDetails(url) { return [{description:'A story'}]; }
    function extractEpisodes(url) { return JSON.stringify([{number:10,href:'fixture://10'},{number:2,href:'fixture://2'}]); }
    function extractStreamUrl(url) { return {streams:[{title:'Server [DUB]',streamUrl:'https://video.example.com/2.m3u8',headers:{Referer:'https://source.example.com/'}}]}; }
    """
    @MainActor func testAsyncModuleFunctionsAndSerializedResults() async throws {
        let validation = try await ModuleRunner.execute(script: script, function: "validate", argument: "")
        XCTAssertTrue(validation.contains("extractStreamUrl"))
        let search = try await ModuleRunner.execute(script: script, function: "searchResults", argument: "A \"quoted\" title")
        let result = try JSONSerialization.jsonObject(with: Data(search.utf8)) as! [[String: Any]]
        XCTAssertEqual(result.first?["title"] as? String, "A \"quoted\" title")
        let episodes = try await ModuleRunner.execute(script: script, function: "extractEpisodes", argument: "fixture://series")
        let rows = try JSONSerialization.jsonObject(with: Data(episodes.utf8)) as! [[String: Any]]
        XCTAssertEqual(ModuleCatalog.parseEpisodes(rows).map(\.number), [2, 10])
    }
    @MainActor func testUnsupportedAndHangingModulesFail() async throws {
        do {
            _ = try await ModuleRunner.execute(script: "function searchResults() {}", function: "validate", argument: "")
            XCTFail("Missing functions accepted")
        } catch { }
        do {
            _ = try await ModuleRunner.execute(script: "function searchResults() { return new Promise(() => {}); }", function: "searchResults", argument: "", timeout: 2)
            XCTFail("Hanging promise accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
    }
    @MainActor func testCancelledModuleDoesNotHang() async throws {
        let task = Task { try await ModuleRunner.execute(script: "function searchResults() { return new Promise(() => {}); }", function: "searchResults", argument: "") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation was ignored") } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
    }
    func testModuleEpisodeIdentityAndAudioArePreserved() throws {
        let module = SourceModule(id: "module:test", manifestURL: URL(string: "https://source.example.com/module.json")!, name: "Fixture", version: "1", baseURL: URL(string: "https://source.example.com")!, script: script, downloads: true)
        let streams: [String: Any] = ["streams": [
            ["title": "Server [SUB]", "streamUrl": "https://video.example.com/sub.m3u8"],
            ["title": "Server [DUB]", "streamUrl": "https://video.example.com/dub.m3u8", "headers": ["Referer": "https://source.example.com/"]],
            ["title": "Server [DUB]", "streamUrl": "https://source.example.com/embed/2"]]]
        let parsed = ModuleCatalog.parseStreams(streams, module: module, audio: .dub)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].audio, .dub)
        XCTAssertEqual(parsed[0].headers["referer"], "https://source.example.com/")
        let episodes = ModuleCatalog.parseEpisodes([
            ["number": 10, "href": "fixture://10"], ["number": 2, "href": "fixture://2", "thumbnail": ["url":"https://images.example.com/2.jpg", "headers":["Referer":"https://source.example.com/"]]],
            ["number": 2, "href": "fixture://duplicate"], ["number": "2.5", "href": "fixture://special"]])
        XCTAssertEqual(episodes.map(\.number), [2, 10])
        XCTAssertEqual(episodes[0].metadata.imageResource?.headers["referer"], "https://source.example.com/")
        var anime = Anime(sourceID: "fixture://series", title: "Fixture")
        anime.moduleID = module.id; anime.moduleEpisodes = episodes
        let decoded = try JSONDecoder().decode(Anime.self, from: JSONEncoder().encode(anime))
        XCTAssertEqual(decoded, anime)
        XCTAssertTrue(decoded.id.hasPrefix("module:test:"))
    }
    @MainActor func testRegistryRestoresAndRemovesOnlySourceCode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("modules.json")
        let module = SourceModule(id: "module:test", manifestURL: URL(string: "https://source.example.com/module.json")!, name: "Fixture", version: "1", baseURL: URL(string: "https://source.example.com")!, script: script, downloads: true)
        try JSONEncoder().encode([module]).write(to: file)
        let registry = ModuleRegistry(file: file)
        XCTAssertEqual(try registry.module(module.id).script, script)
        try registry.remove(module.id)
        XCTAssertTrue(ModuleRegistry(file: file).modules.isEmpty)
    }
}
