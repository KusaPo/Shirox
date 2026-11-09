import XCTest
@testable import Kairo

final class BackgroundHLSDownloadTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func resource(range: HLSByteRange? = nil) -> BackgroundHLSResource {
        BackgroundHLSResource(url: URL(string: "https://media.example/segment.ts")!, name: "v_seg_0.ts", range: range, key: nil, iv: nil, identity: "fixture")
    }
    func testJournalRoundTripPreservesNetworkPolicyAndRequestIdentity() throws {
        var item = resource(range: HLSByteRange(length: 188, offset: 376))
        item.attempts = 3; item.token = "persisted-task"; item.key = Data(repeating: 1, count: 16); item.iv = Data(repeating: 0, count: 16)
        let job = BackgroundHLSJob(id: UUID(), wifiOnly: true, headers: ["Referer": "https://source.example/"], resources: [item], manifests: ["playlist.m3u8": "#EXTM3U"], paused: true)
        let restored = try JSONDecoder().decode(BackgroundHLSJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(restored.id, job.id)
        XCTAssertTrue(restored.wifiOnly); XCTAssertTrue(restored.paused)
        XCTAssertEqual(restored.headers["Referer"], "https://source.example/")
        XCTAssertEqual(restored.resources[0].range?.offset, 376)
        XCTAssertEqual(restored.resources[0].key, item.key)
        XCTAssertEqual(restored.resources[0].token, "persisted-task")
        XCTAssertEqual(restored.resources[0].attempts, 3)
    }
    func testBackgroundResponseCannotPublish429OrAnErrorPage() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("incoming")
        try Data("limited".utf8).write(to: temporary)
        let item = resource()
        let limited = HTTPURLResponse(url: item.url, statusCode: 429, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try item.install(temporary, response: limited, folder: root))
        try Data("<html>blocked</html>".utf8).write(to: temporary)
        let ok = HTTPURLResponse(url: item.url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try item.install(temporary, response: ok, folder: root))
        XCTAssertFalse(item.exists(in: root))
    }
    func testDownloadedRangeSurvivesRecreationAndOnlyPublishesCompleteEpisode() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("incoming")
        try Data([0, 1, 2, 3, 4, 5]).write(to: temporary)
        var item = resource(range: HLSByteRange(length: 3, offset: 2))
        let response = HTTPURLResponse(url: item.url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        var job = BackgroundHLSJob(id: UUID(), wifiOnly: false, headers: [:], resources: [item], manifests: ["playlist.m3u8": "#EXTM3U\n#EXTINF:2,\nv_seg_0.ts\n#EXT-X-ENDLIST\n"])
        XCTAssertThrowsError(try job.finish(in: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("playlist.m3u8").path))
        try item.install(temporary, response: response, folder: root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(item.name)), Data([2, 3, 4]))
        item.complete = true; job.resources = [item]
        let restored = try JSONDecoder().decode(BackgroundHLSJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(restored.fraction, 1)
        let local = try restored.finish(in: root)
        XCTAssertTrue(try String(contentsOf: local, encoding: .utf8).contains("#EXT-X-ENDLIST"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(item.name))
        XCTAssertThrowsError(try restored.finish(in: root))
    }
    func testIncorrectPartialResponseIsRejected() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let item = resource(range: HLSByteRange(length: 3, offset: 2))
        let temporary = root.appendingPathComponent("incoming")
        try Data([1, 2, 3]).write(to: temporary)
        let response = HTTPURLResponse(url: item.url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes 0-2/6"])!
        XCTAssertThrowsError(try item.install(temporary, response: response, folder: root))
        XCTAssertFalse(item.exists(in: root))
    }
}

extension BackgroundHLSDownloadTests {
    func testPreflightBatchesVideoAndAudioBeforeAnyMediaTransfer() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DownloadHTTPClient(wifiOnly: true, transport: { request in
            let url = request.url!
            let text: String
            switch url.lastPathComponent {
            case "master.m3u8":
                text = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"English\",LANGUAGE=\"en\",DEFAULT=YES,URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO=\"audio\"\nvideo.m3u8\n"
            case "video.m3u8", "audio.m3u8":
                text = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\n\(url.lastPathComponent).seg0.ts\n#EXTINF:2,\n\(url.lastPathComponent).seg1.ts\n#EXT-X-ENDLIST\n"
            default: throw KairoError.message("Preflight must not fetch media segments.")
            }
            return (Data(text.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let id = UUID()
        let job = try await HLSDownloadTransfer(client: client).prepareBackground(id: id, url: URL(string: "https://media.example/master.m3u8")!, headers: ["Referer": "https://source.example/"], folder: root, wifiOnly: true)
        XCTAssertEqual(job.id, id)
        XCTAssertEqual(job.resources.count, 4)
        XCTAssertEqual(Set(job.resources.map(\.name)), ["v_seg_0.ts", "v_seg_1.ts", "a0_seg_0.ts", "a0_seg_1.ts"])
        XCTAssertNotNil(job.manifests["audio_0.m3u8"])
        XCTAssertTrue(job.manifests["playlist.m3u8"]?.contains("video.m3u8") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("playlist.m3u8").path))
    }
}


extension BackgroundHLSDownloadTests {
    @MainActor func testDelegatePipelineDownloadsPersistedEpisodeBatch() async throws {
        try await exerciseEpisodeBatch(systemSession: false)
    }
    @MainActor func testDeviceBackgroundServiceDownloadsPersistedEpisodeBatch() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone check: the CI simulator reports remote background session unavailable. The delegate pipeline runs separately with real HTTP transfers.")
        #else
        try await exerciseEpisodeBatch(systemSession: true)
        #endif
    }
    @MainActor private func exerciseEpisodeBatch(systemSession: Bool) async throws {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kairo/Downloads/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data(base64Encoded: HLSDownloadTests.video)!
        try bytes.write(to: source.appendingPathComponent("segment.ts"))
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n"
        let playlist = source.appendingPathComponent("playlist.m3u8")
        try text.write(to: playlist, atomically: true, encoding: .utf8)
        let address = try await OfflineHLSServer.shared.playbackURL(for: playlist)
        let store = AppStore(directory: root.appendingPathComponent("state"))
        let anime = Anime(title: "Background fixture", cover: nil, banner: nil, episodeCount: 1, genres: [])
        let record = DownloadRecord(anime: anime, episode: 1, audio: .sub)
        store.state.downloads = [record]
        let target = root.appendingPathComponent(record.id.uuidString)
        let job = try await HLSDownloadTransfer(client: DownloadHTTPClient(wifiOnly: false)).prepareBackground(id: record.id, url: address, headers: [:], folder: target, wifiOnly: false)
        let factory: ((String, Bool) -> URLSessionConfiguration)? = systemSession ? nil : { _, _ in URLSessionConfiguration.ephemeral }
        let engine = BackgroundHLSDownload(store: store, root: root, sessionPrefix: "net.kusapo.kairo.test." + UUID().uuidString + ".", configurationFactory: factory)
        defer { engine.invalidateForTesting() }
        let restored = expectation(description: "Background sessions restored")
        engine.restore { restored.fulfill() }
        await fulfillment(of: [restored], timeout: 10)
        let completed = expectation(description: "System batch completed")
        engine.onChange = { if store.state.downloads.first?.state == .ready { completed.fulfill() } }
        try engine.start(job)
        await fulfillment(of: [completed], timeout: 60)
        XCTAssertEqual(store.state.downloads.first?.state, .ready)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("v_seg_0.ts")), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("playlist.m3u8").path))
    }
}
